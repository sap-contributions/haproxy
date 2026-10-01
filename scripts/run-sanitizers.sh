#!/bin/bash
#
# run-sanitizers.sh - Build and test haproxy with sanitizers and static analysis
#
# Usage:
#   ./scripts/run-sanitizers.sh [options] [sanitizers...]
#
# Sanitizers:
#   asan    - AddressSanitizer (heap/stack overflow, use-after-free)
#   lsan    - LeakSanitizer (memory leaks; standalone with clang, via asan with gcc)
#   msan    - MemorySanitizer (uninitialized reads; clang-only)
#   tsan    - ThreadSanitizer (data races)
#   ubsan   - UndefinedBehaviorSanitizer (undefined behavior)
#   analyze - GCC -fanalyzer static analysis (compile-time only; gcc-only)
#   scan    - Clang scan-build static analysis (compile-time only)
#   all     - Run all of the above (default; msan included only with clang)
#
# Options:
#   -j N          Parallel jobs for make and vtest (default: nproc)
#   -c CC         Compiler to use (default: gcc-14)
#   -o DIR        Output directory for results (default: /tmp/haproxy-sanitizers-YYYYMMDD-HHMMSS)
#   -t TESTS      Test directory/files (default: reg-tests/)
#   -k            Keep going on sanitizer failure (don't stop)
#   -q            Quiet: only show summary
#   -h            Show this help
#
# Environment variables:
#   VTEST_PROGRAM     Path to vtest binary (auto-detected)
#   HAPROXY_PROGRAM   Path to haproxy binary (default: $PWD/haproxy)
#   MAKE_ARGS         Extra arguments to pass to make
#   REGTESTS_ARGS     Extra arguments to pass to run-regtests.sh
#
# Examples:
#   ./scripts/run-sanitizers.sh                    # Run everything
#   ./scripts/run-sanitizers.sh asan ubsan         # Only ASAN + UBSAN
#   ./scripts/run-sanitizers.sh -j 4 -c gcc tsan   # TSAN with 4 jobs, default gcc
#   ./scripts/run-sanitizers.sh analyze scan        # Static analysis only (no tests)
#

set -euo pipefail

# --- Defaults ---
JOBS=$(nproc 2>/dev/null || echo 4)
CC="${CC:-gcc-14}"
OUTDIR=""
TESTS="reg-tests/"
KEEP_GOING=0
QUIET=0
SANITIZERS=()
SRCDIR="$(cd "$(dirname "$0")/.." && pwd)"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# --- Colors (disabled if not a terminal) ---
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

usage() {
    sed -n '2,/^$/s/^#//p' "$0"
    exit 0
}

log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date +%H:%M:%S)] PASS${NC} $*"; }
fail() { echo -e "${RED}[$(date +%H:%M:%S)] FAIL${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARN${NC} $*"; }
banner() { echo -e "\n${BOLD}========== $* ==========${NC}\n"; }

# --- Parse arguments ---
while [ $# -gt 0 ]; do
    case "$1" in
        -j) JOBS="$2"; shift 2 ;;
        -c) CC="$2"; shift 2 ;;
        -o) OUTDIR="$2"; shift 2 ;;
        -t) TESTS="$2"; shift 2 ;;
        -k) KEEP_GOING=1; shift ;;
        -q) QUIET=1; shift ;;
        -h|--help) usage ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  SANITIZERS+=("$1"); shift ;;
    esac
done

# Detect compiler type
IS_CLANG=0
if $CC --version 2>&1 | grep -qi clang; then
    IS_CLANG=1
fi

# Default: run all
if [ ${#SANITIZERS[@]} -eq 0 ] || [[ " ${SANITIZERS[*]} " == *" all "* ]]; then
    SANITIZERS=(asan lsan tsan ubsan analyze scan)
    # Add msan for clang (not supported by gcc)
    [ "$IS_CLANG" -eq 1 ] && SANITIZERS=(asan lsan msan tsan ubsan analyze scan)
fi

# Output directory
OUTDIR="${OUTDIR:-/tmp/haproxy-sanitizers-${TIMESTAMP}}"
mkdir -p "$OUTDIR"

# --- Detect tools ---
cd "$SRCDIR"

if ! command -v "$CC" &>/dev/null; then
    echo "Error: compiler '$CC' not found" >&2
    exit 1
fi

# Find vtest
if [ -z "${VTEST_PROGRAM:-}" ]; then
    for candidate in /usr/local/bin/vtest /usr/bin/vtest "$HOME/bin/vtest" \
                     "$(dirname "$0")/../bin/vtest"; do
        if [ -x "$candidate" ]; then
            VTEST_PROGRAM="$candidate"
            break
        fi
    done
fi
if [ -z "${VTEST_PROGRAM:-}" ]; then
    warn "vtest not found — sanitizer reg-tests will be skipped"
    warn "Set VTEST_PROGRAM=/path/to/vtest or build with: scripts/build-vtest.sh"
fi

HAPROXY_PROGRAM="${HAPROXY_PROGRAM:-${SRCDIR}/haproxy}"
MAKE_ARGS="${MAKE_ARGS:-}"
REGTESTS_ARGS="${REGTESTS_ARGS:-}"

log "Compiler:    $CC ($($CC --version | head -1))$([ $IS_CLANG -eq 1 ] && echo ' [clang]' || echo ' [gcc]')"
log "Source dir:  $SRCDIR"
log "Output dir:  $OUTDIR"
log "Jobs:        $JOBS"
log "Tests:       $TESTS"
log "Sanitizers:  ${SANITIZERS[*]}"
[ -n "${VTEST_PROGRAM:-}" ] && log "vtest:       $VTEST_PROGRAM"
echo

# --- Summary tracking ---
declare -A RESULTS
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0

record_result() {
    local name="$1" status="$2" detail="${3:-}"
    RESULTS["$name"]="$status"
    case "$status" in
        PASS) ((TOTAL_PASS++)) || true ;;
        FAIL) ((TOTAL_FAIL++)) || true ;;
        SKIP) ((TOTAL_SKIP++)) || true ;;
    esac
    if [ -n "$detail" ]; then
        echo "$detail" >> "$OUTDIR/${name}.detail.txt"
    fi
}

# --- Build helper ---
do_build() {
    local label="$1"
    local extra_cflags="$2"
    local extra_ldflags="${3:-}"
    local logfile="$OUTDIR/${label}-build.log"

    log "Building with $label flags: $extra_cflags"
    make -C "$SRCDIR" clean >"$logfile" 2>&1 || true

    local make_cmd="make -C $SRCDIR -j$JOBS TARGET=linux-glibc CC=$CC"
    make_cmd+=" ARCH_FLAGS=\"$extra_cflags\" USE_LUA=1 USE_OPENSSL=1"
    [ -n "$extra_ldflags" ] && make_cmd+=" LDFLAGS=\"$extra_ldflags\""
    [ -n "$MAKE_ARGS" ] && make_cmd+=" $MAKE_ARGS"

    if eval "$make_cmd" >>"$logfile" 2>&1; then
        log "Build OK"
        return 0
    else
        fail "Build failed — see $logfile"
        tail -20 "$logfile"
        return 1
    fi
}

# --- Test runner helper ---
do_regtests() {
    local label="$1"
    local logfile="$OUTDIR/${label}-tests.log"
    local diagfile="$OUTDIR/${label}-diagnostics.log"

    if [ -z "${VTEST_PROGRAM:-}" ]; then
        warn "Skipping reg-tests (no vtest)"
        record_result "$label" SKIP "vtest not available"
        return 0
    fi

    log "Running reg-tests ($label)..."

    # Record timestamp before running so we can find the log directory after
    local pre_timestamp
    pre_timestamp=$(date +%s)

    local test_output
    test_output=$(VTEST_PROGRAM="$VTEST_PROGRAM" \
        HAPROXY_PROGRAM="$HAPROXY_PROGRAM" \
        "$SRCDIR/scripts/run-regtests.sh" \
            --j "$JOBS" --keep-logs $REGTESTS_ARGS "$TESTS" 2>&1) || true

    echo "$test_output" > "$logfile"

    # Extract test summary line
    local summary
    summary=$(echo "$test_output" | grep -E "^[0-9]+ tests failed" || echo "")
    if [ -z "$summary" ]; then
        summary=$(echo "$test_output" | tail -1)
    fi
    log "Tests: $summary"

    # Find the log directory: most recent haregtests-* dir created after we started
    local test_logdir=""
    local candidate
    for candidate in $(ls -dt /tmp/haregtests-* 2>/dev/null); do
        if [ -d "$candidate" ] && [ "$(stat -c %Y "$candidate")" -ge "$pre_timestamp" ]; then
            test_logdir="$candidate"
            break
        fi
    done
    [ -n "$test_logdir" ] && log "Log dir: $test_logdir"

    # Extract sanitizer diagnostics
    local diag_count=0
    if [ -n "$test_logdir" ] && [ -d "$test_logdir" ]; then
        echo "# $label diagnostics from $test_logdir" > "$diagfile"
        echo "# Generated: $(date)" >> "$diagfile"
        echo "" >> "$diagfile"

        while IFS= read -r logf; do
            local test_name
            test_name=$(head -5 "$logf" 2>/dev/null | grep -oP 'TEST \S+' | head -1 || echo "unknown")
            {
                echo "=== $test_name ==="
                # Extract full sanitizer blocks (error + stack trace + summary)
                grep -E "ERROR:.*Sanitizer|SUMMARY:.*Sanitizer|WARNING:.*Sanitizer|runtime error:|    #[0-9]+ 0x|AddressSanitizer|LeakSanitizer|ThreadSanitizer|UndefinedBehaviorSanitizer" "$logf" 2>/dev/null \
                    | sed 's/^.*debug|//' | sed 's/^.*shell_out|//'
                echo ""
            } >> "$diagfile"
            ((diag_count++)) || true
        done < <(grep -rl "ERROR:.*Sanitizer\|WARNING:.*Sanitizer\|runtime error:\|AddressSanitizer\|LeakSanitizer\|ThreadSanitizer" \
                    "$test_logdir"/*/LOG 2>/dev/null || true)

        # Also capture unique sanitizer summaries
        {
            echo ""
            echo "# Unique sanitizer findings:"
            grep -rh "SUMMARY:.*Sanitizer" "$test_logdir"/*/LOG 2>/dev/null \
                | sed 's/.*SUMMARY: //' | sort -u
        } >> "$diagfile" 2>/dev/null || true

        # For TSAN: extract unique race locations
        if [[ "$label" == "tsan" ]]; then
            {
                echo ""
                echo "# Unique data race locations (top 30):"
                grep -rh "    #[01] .*haproxy" "$test_logdir"/*/LOG 2>/dev/null \
                    | grep -v "tsan\|libc\|pthread" \
                    | sed 's/.*#[01] [0-9a-fx]* in //' | sed 's/ (.*//' \
                    | sort | uniq -c | sort -rn | head -30
                echo ""
                echo "# Total test logs with data races:"
                grep -rl "data race" "$test_logdir"/*/LOG 2>/dev/null | wc -l
            } >> "$diagfile" 2>/dev/null || true
        fi
    fi

    if [ "$diag_count" -gt 0 ]; then
        warn "$label: $diag_count test(s) with sanitizer findings — see $diagfile"
        record_result "$label" FAIL "$diag_count test(s) with sanitizer findings"
        return 1
    fi

    # Fallback: also scan the captured test output itself (in case log dirs were lost)
    local output_diags=0
    output_diags=$(grep -cE "ERROR:.*Sanitizer|WARNING:.*ThreadSanitizer|runtime error:" "$logfile" 2>/dev/null || echo 0)
    if [ "$output_diags" -gt 0 ]; then
        warn "$label: $output_diags sanitizer line(s) found in test output — see $logfile"
        grep -E "ERROR:.*Sanitizer|SUMMARY:.*Sanitizer|WARNING:.*Sanitizer|runtime error:" "$logfile" \
            | sort -u > "$diagfile" 2>/dev/null || true
        record_result "$label" FAIL "$output_diags sanitizer line(s) in output"
        return 1
    fi

    ok "$label: no sanitizer findings"
    record_result "$label" PASS
    return 0
}

# --- Static analysis: gcc -fanalyzer ---
run_gcc_analyzer() {
    banner "GCC Static Analyzer (-fanalyzer)"
    local logfile="$OUTDIR/analyze-build.log"

    # -fanalyzer is GCC-only; for Clang, redirect to scan-build
    if [ "$IS_CLANG" -eq 1 ]; then
        warn "-fanalyzer is GCC-only; use 'scan' for Clang static analysis"
        record_result "analyze" SKIP "GCC-only (use 'scan' for clang)"
        return 0
    fi

    log "Building with -fanalyzer (compile-time analysis)..."
    make -C "$SRCDIR" clean >"$logfile" 2>&1 || true

    local warnings=0
    if make -C "$SRCDIR" -j"$JOBS" TARGET=linux-glibc CC="$CC" \
         ARCH_FLAGS="-fanalyzer -g" USE_LUA=1 USE_OPENSSL=1 \
         $MAKE_ARGS >>"$logfile" 2>&1; then
        log "Build completed"
    else
        # -fanalyzer may produce warnings but still succeed; check if binary exists
        if [ -x "$SRCDIR/haproxy" ]; then
            log "Build completed with warnings"
        else
            fail "Build failed — see $logfile"
            record_result "analyze" FAIL "build failed"
            return 1
        fi
    fi

    # Extract analyzer warnings
    local warnfile="$OUTDIR/analyze-warnings.log"
    grep -E "\-Wanalyzer\-|warning:.*\[analyzer" "$logfile" > "$warnfile" 2>/dev/null || true
    warnings=$(wc -l < "$warnfile")

    if [ "$warnings" -gt 0 ]; then
        local unique_warnings
        unique_warnings=$(sed 's/^.*warning: //' "$warnfile" | sort -u | wc -l)
        warn "GCC analyzer: $warnings warnings ($unique_warnings unique) — see $warnfile"
        if [ "$QUIET" -eq 0 ]; then
            echo "  Top warnings:"
            sed 's/^.*warning: //' "$warnfile" | sort | uniq -c | sort -rn | head -10 | sed 's/^/    /'
        fi
        record_result "analyze" FAIL "$warnings warnings ($unique_warnings unique)"
    else
        ok "GCC analyzer: no warnings"
        record_result "analyze" PASS
    fi
}

# --- Static analysis: scan-build ---
run_scan_build() {
    banner "Clang scan-build"

    if ! command -v scan-build &>/dev/null; then
        warn "scan-build not found — skipping"
        record_result "scan" SKIP "scan-build not installed"
        return 0
    fi

    local logfile="$OUTDIR/scan-build.log"
    local scan_outdir="$OUTDIR/scan-build-results"

    log "Running scan-build..."
    make -C "$SRCDIR" clean >"$logfile" 2>&1 || true

    scan-build -o "$scan_outdir" \
        --use-cc="$CC" \
        -enable-checker security \
        -enable-checker deadcode \
        -enable-checker nullability \
        make -C "$SRCDIR" -j"$JOBS" TARGET=linux-glibc CC="$CC" \
             USE_LUA=1 USE_OPENSSL=1 \
             $MAKE_ARGS >>"$logfile" 2>&1 || true

    # Count bugs found
    local bug_count=0
    if [ -d "$scan_outdir" ]; then
        bug_count=$(find "$scan_outdir" -name "*.html" 2>/dev/null | wc -l)
    fi

    # Also extract from log
    local log_bugs
    log_bugs=$(grep -c "warning: " "$logfile" 2>/dev/null || echo 0)

    if [ "$bug_count" -gt 0 ] || [ "$log_bugs" -gt 0 ]; then
        warn "scan-build: $bug_count reports, $log_bugs warnings — see $scan_outdir"
        record_result "scan" FAIL "$bug_count reports, $log_bugs warnings"
    else
        ok "scan-build: clean"
        record_result "scan" PASS
    fi
}

# --- Main loop ---
for san in "${SANITIZERS[@]}"; do
    case "$san" in
        asan)
            banner "AddressSanitizer (ASAN)"
            if do_build "asan" "-fsanitize=address -g"; then
                do_regtests "asan" || [ "$KEEP_GOING" -eq 1 ] || true
            else
                record_result "asan" FAIL "build failed"
            fi
            ;;
        lsan)
            banner "LeakSanitizer (LSAN)"
            lsan_flags="-fsanitize=address -g"
            if [ "$IS_CLANG" -eq 1 ]; then
                # Clang supports standalone -fsanitize=leak (lighter than full ASAN)
                lsan_flags="-fsanitize=leak -fPIE -g"
            fi
            if do_build "lsan" "$lsan_flags"; then
                export LSAN_OPTIONS="exitcode=0:print_suppressions=0"
                do_regtests "lsan" || [ "$KEEP_GOING" -eq 1 ] || true
                unset LSAN_OPTIONS
            else
                record_result "lsan" FAIL "build failed"
            fi
            ;;
        tsan)
            banner "ThreadSanitizer (TSAN)"
            if do_build "tsan" "-fsanitize=thread -g"; then
                export TSAN_OPTIONS="exitcode=0:second_deadlock_stack=1"
                do_regtests "tsan" || [ "$KEEP_GOING" -eq 1 ] || true
                unset TSAN_OPTIONS
            else
                record_result "tsan" FAIL "build failed"
            fi
            ;;
        ubsan)
            banner "UndefinedBehaviorSanitizer (UBSAN)"
            if do_build "ubsan" "-fsanitize=undefined -g -fno-sanitize-recover=all"; then
                do_regtests "ubsan" || [ "$KEEP_GOING" -eq 1 ] || true
            else
                # -fno-sanitize-recover may be too strict; retry without it
                warn "Retrying UBSAN build without -fno-sanitize-recover"
                if do_build "ubsan" "-fsanitize=undefined -g"; then
                    do_regtests "ubsan" || [ "$KEEP_GOING" -eq 1 ] || true
                else
                    record_result "ubsan" FAIL "build failed"
                fi
            fi
            ;;
        msan)
            banner "MemorySanitizer (MSAN)"
            if [ "$IS_CLANG" -eq 0 ]; then
                warn "MSAN is only supported by Clang — skipping"
                record_result "msan" SKIP "requires clang"
            else
                if do_build "msan" "-fsanitize=memory -g -fno-omit-frame-pointer"; then
                    do_regtests "msan" || [ "$KEEP_GOING" -eq 1 ] || true
                else
                    record_result "msan" FAIL "build failed"
                fi
            fi
            ;;
        analyze)
            run_gcc_analyzer
            ;;
        scan)
            run_scan_build
            ;;
        *)
            warn "Unknown sanitizer: $san"
            ;;
    esac
done

# --- Final Summary ---
banner "SUMMARY"
echo -e "Results in: ${BOLD}$OUTDIR${NC}"
echo ""
printf "  %-12s %s\n" "SANITIZER" "RESULT"
printf "  %-12s %s\n" "---------" "------"
for san in "${SANITIZERS[@]}"; do
    status="${RESULTS[$san]:-SKIP}"
    case "$status" in
        PASS) color="$GREEN" ;;
        FAIL) color="$RED" ;;
        *)    color="$YELLOW" ;;
    esac
    detail=""
    [ -f "$OUTDIR/${san}.detail.txt" ] && detail=" ($(cat "$OUTDIR/${san}.detail.txt"))"
    printf "  %-12s ${color}%-6s${NC}%s\n" "$san" "$status" "$detail"
done
echo ""
echo -e "  Total: ${GREEN}$TOTAL_PASS passed${NC}, ${RED}$TOTAL_FAIL failed${NC}, ${YELLOW}$TOTAL_SKIP skipped${NC}"
echo ""

# List generated files
echo "Output files:"
ls -1 "$OUTDIR"/ | sed 's/^/  /'
echo ""

# Exit with failure if any sanitizer failed
[ "$TOTAL_FAIL" -eq 0 ]
