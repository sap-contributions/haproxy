#!/usr/bin/env bash
# Diagnostic for the lra==TICK_ETERNITY concern raised against fix
# f218e2252 (GH #3351).  The companion regtest mcli_master_socket_leak.vtc
# uses "debug dev delay" to block the worker INSIDE its CLI handler,
# at which point lra has already advanced.  This script freezes the
# worker at the OS level via SIGSTOP BEFORE any byte flows back, then
# checks whether slots are still freed on client disconnect.
#
# Empirical result on this branch: slots ARE freed even under SIGSTOP.
# The 11th connection attempt succeeds in ~0.5s while the worker is
# still frozen.  Likely explanation: lra is set when the backend
# stconn enters EST state during sockpair setup (which happens at the
# kernel level immediately because sockpairs are pre-connected), not
# when the worker actually reads a byte.  SIGSTOP'ing the worker
# doesn't unwind that master-side state, so sc_set_hcto() arms a
# real, finite expiry on client disconnect.
#
# Strategy:
#   1) Start haproxy in master-worker mode with a master CLI on a TCP port.
#   2) Discover the worker PID via "show proc".
#   3) SIGSTOP the worker BEFORE any client traffic.
#   4) Fill all 10 master CLI slots with clients that get killed after 2s.
#   5) Try the 11th connection while worker is STILL SIGSTOPped.
#   6) SIGCONT the worker, sanity-check master CLI, clean up.
#
# Pass criteria:
#   - 11th connection succeeds within a few seconds while SIGSTOPped =>
#     fix covers SIGSTOP case (this is what we observe).
#   - 11th connection refused/hangs => slots leaked, lra concern real.

set -u
set -o pipefail

HAPROXY_BIN="${HAPROXY_BIN:-./haproxy}"
TMPDIR="$(mktemp -d -t mcli-sigstop.XXXXXX)"
MCLI_HOST="127.0.0.1"
MCLI_PORT="$((20000 + RANDOM % 10000))"
FE_PORT="$((20000 + RANDOM % 10000))"

cleanup() {
    rc=$?
    # Always try to unfreeze the worker before exiting, no matter what.
    if [ -n "${WORKER_PID:-}" ]; then
        kill -CONT "$WORKER_PID" 2>/dev/null || true
    fi
    if [ -n "${MASTER_PID:-}" ]; then
        kill -TERM "$MASTER_PID" 2>/dev/null || true
        wait "$MASTER_PID" 2>/dev/null || true
    fi
    rm -rf "$TMPDIR"
    exit $rc
}
trap cleanup EXIT INT TERM

echo "==> tmpdir:        $TMPDIR"
echo "==> haproxy:       $HAPROXY_BIN"
echo "==> master CLI:    $MCLI_HOST:$MCLI_PORT"
echo "==> frontend port: $FE_PORT"

cat > "$TMPDIR/haproxy.cfg" <<EOF
global
    nbthread 1

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

# Start in master-worker mode with TCP master CLI (-S binds master CLI).
echo "==> starting haproxy ..."
"$HAPROXY_BIN" -W -S "${MCLI_HOST}:${MCLI_PORT}" -f "$TMPDIR/haproxy.cfg" \
    > "$TMPDIR/haproxy.log" 2>&1 &
MASTER_PID=$!

# Wait for master CLI to come up
for i in $(seq 1 50); do
    if printf "show version\n" | socat -t1 "TCP:${MCLI_HOST}:${MCLI_PORT}" - >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

# Discover the worker PID via "show proc"
echo "==> discovering worker PID ..."
SHOW_PROC=$(printf "show proc\n" | socat -t2 "TCP:${MCLI_HOST}:${MCLI_PORT}" - 2>/dev/null)
echo "----- show proc output -----"
echo "$SHOW_PROC"
echo "----------------------------"

WORKER_PID=$(echo "$SHOW_PROC" | awk '$1 ~ /^[0-9]+$/ && $0 ~ /worker/ { print $1; exit }')
if [ -z "${WORKER_PID:-}" ]; then
    echo "FAIL: could not parse worker PID from show proc"
    exit 1
fi
echo "==> worker pid: $WORKER_PID"

# Freeze the worker BEFORE any client traffic.
echo "==> SIGSTOP worker $WORKER_PID"
kill -STOP "$WORKER_PID"

# Fill ALL 10 slots (no diagnostic slot left).  If the fix works under
# SIGSTOP, the 11th connection attempt below should still succeed within
# a couple of seconds.  If slots truly leak, it should be refused with
# "Resource temporarily unavailable" or hang.
echo "==> filling all 10 master CLI slots with clients that will time out ..."
SOCAT_PIDS=()
for i in $(seq 1 10); do
    (printf "@1 show info\n" \
     | timeout --kill-after=1 2 socat "TCP:${MCLI_HOST}:${MCLI_PORT}" - 2>/dev/null) &
    SOCAT_PIDS+=($!)
done
for pid in "${SOCAT_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done
echo "==> 10 client timeouts complete"

# Crucial test: try the 11th connection while the worker is STILL SIGSTOPped.
# If the slots were freed on client disconnect, this succeeds.
# If they leaked, this fails or hangs.
echo "==> 11th connection attempt while worker is still SIGSTOPped ..."
T0=$(date +%s.%N)
RESULT=$(printf "show version\n" | timeout --kill-after=1 5 socat -t4 "TCP:${MCLI_HOST}:${MCLI_PORT}" - 2>&1)
RC=$?
T1=$(date +%s.%N)
ELAPSED=$(awk "BEGIN { printf \"%.2f\", $T1 - $T0 }")
echo "    rc=$RC elapsed=${ELAPSED}s"
echo "    raw: $RESULT"
echo
if [ $RC -eq 0 ] && echo "$RESULT" | grep -qE '[0-9]+\.[0-9]+'; then
    echo "    -> SLOTS WERE FREED while worker was SIGSTOPped: fix covers this case."
else
    echo "    -> SLOTS LEAKED: 11th connection failed/hung while worker SIGSTOPped."
    echo "       This would confirm the lra==TICK_ETERNITY concern."
fi

# Unfreeze
echo
echo "==> SIGCONT worker $WORKER_PID"
kill -CONT "$WORKER_PID"
WORKER_PID=""  # so cleanup doesn't double-CONT

# Final reachability check after SIGCONT
echo "==> final reachability check (worker resumed) ..."
FINAL=$(printf "show version\n" | timeout --kill-after=1 5 socat -t4 "TCP:${MCLI_HOST}:${MCLI_PORT}" - 2>&1)
echo "    raw: $FINAL"
if echo "$FINAL" | grep -qE '[0-9]+\.[0-9]+'; then
    echo "    OK: master CLI is reachable after worker resumed."
else
    echo "    FAIL: master CLI not reachable even after worker resumed."
    exit 1
fi
