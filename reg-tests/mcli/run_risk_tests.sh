#!/usr/bin/env bash
# Risk validation harness for the master CLI slot-leak fix.
#
# Tests three scenarios that could plausibly regress with the patch:
#   #1 pipelined commands  — client sends multiple commands, disconnects
#                            at various points; verify output is intact and
#                            slots are freed.
#   #2 reload during CLI traffic — issue a reload while CLI clients are
#                                  hitting @1-prefixed commands; count the
#                                  client-visible failures during the
#                                  reload window.
#   #3 long-running command cut off — client connects, sends a slow
#                                     command, disconnects mid-response;
#                                     verify worker is still healthy
#                                     afterward and slot was freed.
#
# Run as: ./run_risk_tests.sh /path/to/haproxy
# Without arguments, defaults to ./haproxy.
#
# Output is plain-text counters per test.  Compare two runs (baseline vs
# patched) by running this script twice with different binaries.

set -u
set -o pipefail

HAPROXY_BIN="${1:-./haproxy}"
LABEL="${2:-$(basename "$HAPROXY_BIN")}"
TMPDIR="$(mktemp -d -t mcli-risk.XXXXXX)"
MCLI_HOST="127.0.0.1"
MCLI_PORT="$((20000 + RANDOM % 10000))"
FE_PORT="$((20000 + RANDOM % 10000))"

# Result counters
P1_PASS=0; P1_FAIL=0; P1_NOTES=""
P2_PASS=0; P2_FAIL=0; P2_NOTES=""
P3_PASS=0; P3_FAIL=0; P3_NOTES=""

cleanup() {
    rc=$?
    if [ -n "${MASTER_PID:-}" ]; then
        kill -TERM "$MASTER_PID" 2>/dev/null || true
        wait "$MASTER_PID" 2>/dev/null || true
    fi
    rm -rf "$TMPDIR"
    exit $rc
}
trap cleanup EXIT INT TERM

note() { echo "    $*"; }

mcli_send() {
    # mcli_send <timeout-secs> <commands...>
    local t="$1"; shift
    printf "%s\n" "$@" \
        | timeout --kill-after=1 "$t" socat -t"$((t-1))" "TCP:${MCLI_HOST}:${MCLI_PORT}" - 2>/dev/null
}

start_haproxy() {
    local extra_global="${1:-}"
    cat > "$TMPDIR/haproxy.cfg" <<EOF
global
    nbthread 1
    ${extra_global}

defaults
    mode http
    timeout connect 5s
    timeout client  5s
    timeout server  5s

frontend fe
    bind 127.0.0.1:${FE_PORT}
    default_backend be

backend be
    server s1 127.0.0.1:9
EOF
    "$HAPROXY_BIN" -W -S "${MCLI_HOST}:${MCLI_PORT}" -f "$TMPDIR/haproxy.cfg" \
        > "$TMPDIR/haproxy.log" 2>&1 &
    MASTER_PID=$!
    for _ in $(seq 1 50); do
        if mcli_send 1 "show version" >/dev/null 2>&1; then return 0; fi
        sleep 0.1
    done
    return 1
}

stop_haproxy() {
    if [ -n "${MASTER_PID:-}" ]; then
        kill -TERM "$MASTER_PID" 2>/dev/null || true
        wait "$MASTER_PID" 2>/dev/null || true
        MASTER_PID=""
    fi
}

worker_pid() {
    mcli_send 2 "show proc" \
        | awk '$1 ~ /^[0-9]+$/ && $0 ~ /worker/ { print $1; exit }'
}

##############################################################################
# Test #1: pipelined commands
##############################################################################
test_pipeline() {
    echo
    echo "===> Test #1: pipelined commands ($LABEL)"
    start_haproxy || { P1_FAIL=$((P1_FAIL+1)); note "haproxy failed to start"; return; }

    # 1a: 3 local commands pipelined, client reads to EOF
    local out
    out=$(mcli_send 5 "show version" "show proc" "show version")
    local n_versions n_proc
    n_versions=$(echo "$out" | grep -cE '^[0-9]+\.[0-9]+' || true)
    n_proc=$(echo "$out" | grep -c '# workers' || true)
    if [ "$n_versions" -ge 2 ] && [ "$n_proc" -ge 1 ]; then
        P1_PASS=$((P1_PASS+1))
        note "1a PASS: 3 local pipelined commands all produced output"
    else
        P1_FAIL=$((P1_FAIL+1))
        note "1a FAIL: expected >=2 version lines and a workers section; got $n_versions versions, $n_proc proc"
    fi

    # 1b: 3 forwarded commands pipelined to worker
    out=$(mcli_send 5 "@1 show version" "@1 show info" "@1 show stat")
    local has_version has_info
    has_version=$(echo "$out" | grep -cE '^[0-9]+\.[0-9]+' || true)
    has_info=$(echo "$out" | grep -c 'Process_num' || true)
    if [ "$has_version" -ge 1 ] && [ "$has_info" -ge 1 ]; then
        P1_PASS=$((P1_PASS+1))
        note "1b PASS: 3 forwarded pipelined commands produced expected markers"
    else
        P1_FAIL=$((P1_FAIL+1))
        note "1b FAIL: forwarded pipelined output incomplete (version=$has_version info=$has_info)"
    fi

    # 1c: pipelined commands with hard mid-stream disconnect (no FIN).
    # Send commands, then SIGKILL socat so the kernel cleans up the socket
    # without sending a clean FIN.  This is the actual leak trigger — a
    # graceful timeout(1)/SIGTERM is recovered cleanly even on baseline
    # because socat closes its end before exiting.
    # After the disconnect, verify the master CLI still works.
    local PIDS=()
    for i in 1 2 3; do
        (printf "@1 show info\n@1 show stat\n@1 show servers state\n" \
         | socat -t10 "TCP:${MCLI_HOST}:${MCLI_PORT}" - >/dev/null 2>&1) &
        PIDS+=($!)
    done
    sleep 0.5  # let the commands reach the worker
    for p in "${PIDS[@]}"; do kill -9 "$p" 2>/dev/null || true; done
    for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    sleep 1.5  # give server-fin (1s) time to fire on patched build
    if mcli_send 3 "show version" | grep -qE '[0-9]+\.[0-9]+'; then
        P1_PASS=$((P1_PASS+1))
        note "1c PASS: master CLI reachable after hard mid-stream disconnect"
    else
        P1_FAIL=$((P1_FAIL+1))
        note "1c FAIL: master CLI unreachable after hard mid-stream disconnect"
    fi

    # 1d: the actual bug scenario — frozen worker + 10 SIGKILL'd clients.
    # On baseline: slots leak permanently while worker frozen, 11th conn fails.
    # On patched: server-fin fires at 1s, slots freed, 11th conn succeeds.
    local wpid
    wpid=$(worker_pid)
    if [ -n "$wpid" ]; then
        kill -STOP "$wpid"
        local PIDS2=()
        for i in $(seq 1 10); do
            (printf "@1 show info\n" \
             | socat -t30 "TCP:${MCLI_HOST}:${MCLI_PORT}" - >/dev/null 2>&1) &
            PIDS2+=($!)
        done
        sleep 1
        for p in "${PIDS2[@]}"; do kill -9 "$p" 2>/dev/null || true; done
        for pid in "${PIDS2[@]}"; do wait "$pid" 2>/dev/null || true; done
        sleep 2  # give server-fin (1s) time to fire on patched build

        local t0 t1 result elapsed
        t0=$(date +%s.%N)
        result=$(mcli_send 4 "show version")
        t1=$(date +%s.%N)
        elapsed=$(awk "BEGIN { printf \"%.2f\", $t1 - $t0 }")
        kill -CONT "$wpid" 2>/dev/null || true

        # Note: this is the bug trigger.  We expect baseline to FAIL and
        # patched to PASS.  Both outcomes are useful diagnostic data.
        if echo "$result" | grep -qE '[0-9]+\.[0-9]+'; then
            P1_PASS=$((P1_PASS+1))
            note "1d PASS: 11th conn succeeded in ${elapsed}s with frozen worker (slots freed)"
        else
            P1_FAIL=$((P1_FAIL+1))
            note "1d FAIL: 11th conn failed in ${elapsed}s with frozen worker (slots leaked) — expected on baseline, regression on patched"
        fi
    else
        note "1d SKIP: could not get worker PID"
    fi

    stop_haproxy
}

##############################################################################
# Test #2: reload during CLI traffic
##############################################################################
test_reload_during_traffic() {
    echo
    echo "===> Test #2: reload during CLI traffic ($LABEL)"

    # Build a config with enough backends to make parse non-trivial.  Even
    # so, reloads on a local box are typically <0.5s.  We compensate by
    # making the in-flight CLI work artificially slow with "debug dev
    # delay" so it actually overlaps the reload window.
    local cfg="$TMPDIR/reload_haproxy.cfg"
    {
        echo "global"
        echo "    nbthread 1"
        echo "    expose-experimental-directives"
        echo
        echo "defaults"
        echo "    mode http"
        echo "    timeout connect 5s"
        echo "    timeout client  5s"
        echo "    timeout server  5s"
        echo
        echo "frontend fe"
        echo "    bind 127.0.0.1:${FE_PORT}"
        echo "    default_backend be0"
        echo
        for i in $(seq 0 200); do
            echo "backend be${i}"
            echo "    server s1 127.0.0.1:9"
        done
    } > "$cfg"

    "$HAPROXY_BIN" -W -S "${MCLI_HOST}:${MCLI_PORT}" -f "$cfg" \
        > "$TMPDIR/haproxy.log" 2>&1 &
    MASTER_PID=$!
    for _ in $(seq 1 50); do
        if mcli_send 1 "show version" >/dev/null 2>&1; then break; fi
        sleep 0.1
    done

    # 2a: time the reload itself (no concurrent traffic).
    local t0 t1 reload_out elapsed_reload
    t0=$(date +%s.%N)
    reload_out=$(mcli_send 10 "reload")
    t1=$(date +%s.%N)
    elapsed_reload=$(awk "BEGIN { printf \"%.3f\", $t1 - $t0 }")
    note "reload alone took ${elapsed_reload}s; result: $(echo "$reload_out" | head -1)"

    if echo "$reload_out" | grep -qiE 'Success|Loading'; then
        P2_PASS=$((P2_PASS+1))
        note "2a PASS: reload command succeeded"
    else
        P2_FAIL=$((P2_FAIL+1))
        note "2a FAIL: reload did not return Success (out: $reload_out)"
    fi

    # 2b: in-flight CLI commands during reload.  Start 5 background
    # @1-prefixed slow-delay commands (each blocks worker thread for 2s
    # via debug dev delay).  Wait briefly so they reach the worker, then
    # issue a reload.  Count successes vs. failures of the in-flight
    # commands.
    local inflight_log="$TMPDIR/inflight.log"
    : > "$inflight_log"
    local INFLIGHT_PIDS=()
    for i in $(seq 1 5); do
        (
            r=$(printf "expert-mode on\n@1 debug dev delay 2000\n" \
                | timeout --kill-after=1 8 socat -t6 "TCP:${MCLI_HOST}:${MCLI_PORT}" - \
                  2>&1 || echo "TIMEOUT")
            if [ -z "$r" ]; then
                echo "EMPTY $i" >> "$inflight_log"
            elif echo "$r" | grep -q "Can't connect"; then
                echo "CANTCONN $i" >> "$inflight_log"
            elif echo "$r" | grep -q TIMEOUT; then
                echo "TIMEOUT $i" >> "$inflight_log"
            else
                echo "OK $i" >> "$inflight_log"
            fi
        ) &
        INFLIGHT_PIDS+=($!)
    done

    # Let in-flight commands settle into the worker.
    sleep 0.3

    # Issue the reload while in-flight commands are running.
    t0=$(date +%s.%N)
    reload_out=$(mcli_send 10 "reload")
    t1=$(date +%s.%N)
    local elapsed_reload2
    elapsed_reload2=$(awk "BEGIN { printf \"%.3f\", $t1 - $t0 }")

    for pid in "${INFLIGHT_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done

    local inflight_ok inflight_cantconn inflight_timeout inflight_empty
    inflight_ok=$(grep -c '^OK ' "$inflight_log" || true)
    inflight_cantconn=$(grep -c '^CANTCONN ' "$inflight_log" || true)
    inflight_timeout=$(grep -c '^TIMEOUT ' "$inflight_log" || true)
    inflight_empty=$(grep -c '^EMPTY ' "$inflight_log" || true)

    note "reload during in-flight took ${elapsed_reload2}s"
    note "in-flight outcomes: ok=$inflight_ok cantconn=$inflight_cantconn timeout=$inflight_timeout empty=$inflight_empty"

    # The reload itself must still succeed even with traffic in flight.
    if echo "$reload_out" | grep -qiE 'Success|Loading'; then
        P2_PASS=$((P2_PASS+1))
        note "2b PASS: reload during in-flight traffic succeeded"
    else
        P2_FAIL=$((P2_FAIL+1))
        note "2b FAIL: reload-during-traffic did not return Success (out: $reload_out)"
    fi

    P2_NOTES="reload=${elapsed_reload}s reload-w-traffic=${elapsed_reload2}s inflight: ok=$inflight_ok cc=$inflight_cantconn to=$inflight_timeout empty=$inflight_empty"
    stop_haproxy
}

##############################################################################
# Test #3: long-running command cut off
##############################################################################
test_long_command_cutoff() {
    echo
    echo "===> Test #3: long-running command cut off ($LABEL)"
    start_haproxy || { P3_FAIL=$((P3_FAIL+1)); note "haproxy failed to start"; return; }

    # 3a: client sends a slow command and is SIGKILLed mid-stream (no FIN).
    # Use "expert-mode on; @1 debug dev delay 3000" to force a 3s worker delay.
    # Client is killed at ~0.5s, well before the delay completes, with no
    # graceful FIN.
    (printf "expert-mode on\n@1 debug dev delay 3000\n" \
     | socat -t10 "TCP:${MCLI_HOST}:${MCLI_PORT}" - >/dev/null 2>&1) &
    local p3a=$!
    sleep 0.5
    kill -9 "$p3a" 2>/dev/null || true
    wait "$p3a" 2>/dev/null || true
    # Wait long enough for worker to finish its delay AND server-fin (1s) to fire.
    sleep 4

    # 3b: verify worker is still responsive after the cut-off.
    local out
    out=$(mcli_send 4 "@1 show info")
    if echo "$out" | grep -q 'Process_num'; then
        P3_PASS=$((P3_PASS+1))
        note "3a PASS: worker still responsive after long-command cut-off"
    else
        P3_FAIL=$((P3_FAIL+1))
        note "3a FAIL: worker not responsive (out head: $(echo "$out" | head -c 100))"
    fi

    # 3c: fill all 10 slots with the same SIGKILL pattern; after they all
    # disconnect, master CLI should still accept new connections.
    local PIDS=()
    for i in $(seq 1 10); do
        (printf "expert-mode on\n@1 debug dev delay 5000\n" \
         | socat -t30 "TCP:${MCLI_HOST}:${MCLI_PORT}" - >/dev/null 2>&1) &
        PIDS+=($!)
    done
    sleep 0.5
    for p in "${PIDS[@]}"; do kill -9 "$p" 2>/dev/null || true; done
    for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    # Must wait for worker delay to finish (5s) + server-fin (1s).
    # Without server-fin (baseline), this still passes if the worker eventually
    # finishes and writes to the broken sockpair (gets EPIPE) and frees its slot.
    sleep 7

    if mcli_send 4 "show version" | grep -qE '[0-9]+\.[0-9]+'; then
        P3_PASS=$((P3_PASS+1))
        note "3b PASS: master CLI reachable after 10 cut-off long commands"
    else
        P3_FAIL=$((P3_FAIL+1))
        note "3b FAIL: master CLI unreachable after 10 cut-off long commands"
    fi

    stop_haproxy
}

##############################################################################
# Main
##############################################################################
echo "=========================================================="
echo "Risk validation harness"
echo "binary: $HAPROXY_BIN"
echo "label:  $LABEL"
echo "tmpdir: $TMPDIR"
echo "=========================================================="

# Verify binary exists and runs.
if ! "$HAPROXY_BIN" -v >/dev/null 2>&1; then
    echo "ERROR: $HAPROXY_BIN is not a working haproxy binary"
    exit 2
fi
"$HAPROXY_BIN" -v 2>&1 | head -1

test_pipeline
test_reload_during_traffic
test_long_command_cutoff

echo
echo "=========================================================="
echo "RESULTS for $LABEL"
echo "=========================================================="
printf "  #1 pipelined commands:        pass=%d fail=%d\n" "$P1_PASS" "$P1_FAIL"
printf "  #2 reload during traffic:     pass=%d fail=%d  (%s)\n" "$P2_PASS" "$P2_FAIL" "$P2_NOTES"
printf "  #3 long-command cut-off:      pass=%d fail=%d\n" "$P3_PASS" "$P3_FAIL"
echo
total_fail=$((P1_FAIL + P2_FAIL + P3_FAIL))
if [ $total_fail -eq 0 ]; then
    echo "OVERALL: all assertions passed"
else
    echo "OVERALL: $total_fail assertion(s) failed"
fi
exit $total_fail
