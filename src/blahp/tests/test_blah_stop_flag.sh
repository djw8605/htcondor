#!/bin/bash
#
# Tests for bls_check_stop_flag: the site-side submission block used by the
# ce_control red button.
#
# Self-contained -- needs no batch system, no blahpd, and no installed blahp.
# It builds a throwaway BLAHPD_LOCATION whose libexec is symlinked to the real
# scripts, drops a stub submit script in it, and drives that stub the way a real
# *_submit.sh would be driven.
#
# Usage: ./test_blah_stop_flag.sh
#

set -u

SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../src/scripts" && pwd)

tests_run=0
tests_failed=0

fail() {
    tests_failed=$((tests_failed + 1))
    echo "  FAIL: $1"
    [ $# -gt 1 ] && echo "$2" | sed 's/^/        /'
    return 0
}

assert_contains() {
    # assert_contains <haystack> <needle> <description>
    case "$1" in
        *"$2"*) return 0 ;;
        *) fail "$3" "expected to contain: $2
actual: $1" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) fail "$3" "expected NOT to contain: $2
actual: $1" ;;
        *) return 0 ;;
    esac
}

assert_equals() {
    if [ "$1" != "$2" ]; then
        fail "$3" "expected: $2
actual:   $1"
    fi
}

# Build a throwaway blahp install and run the stub submit script in it.
#
# Sets: run_stdout, run_stderr, run_status
# Args: any extra env assignments are inherited from the caller.
setup_sandbox() {
    TESTROOT=$(mktemp -d "${TMPDIR:-/tmp}/blahstopflag.XXXXXX")
    FAKE_HOME="$TESTROOT/home"
    BLAHPD_LOCATION="$TESTROOT/glite"
    mkdir -p "$FAKE_HOME" "$BLAHPD_LOCATION/libexec" "$BLAHPD_LOCATION/etc" \
             "$BLAHPD_LOCATION/bin" "$BLAHPD_LOCATION/sbin"

    # Real scripts, so the test exercises the shipped code.
    ln -s "$SCRIPTS_DIR"/*.sh "$BLAHPD_LOCATION/libexec/" 2>/dev/null

    # Minimal config so blah_load_config.sh does not reach for /etc/blah.config.
    : > "$BLAHPD_LOCATION/etc/blah.config"

    # A stub standing in for slurm_submit.sh et al: it does exactly what they do
    # -- source the common functions and parse options -- then announces that it
    # got past the gate.
    cat > "$BLAHPD_LOCATION/libexec/test_submit.sh" <<'STUB'
#!/bin/bash
. `dirname $0`/blah_common_submit_functions.sh
bls_parse_submit_options "$@"
echo "SUBMIT_PROCEEDED"
STUB
    chmod +x "$BLAHPD_LOCATION/libexec/test_submit.sh"
}

teardown_sandbox() {
    [ -n "${TESTROOT:-}" ] && rm -rf "$TESTROOT"
}

run_submit() {
    local out_f err_f
    out_f="$TESTROOT/stdout" ; err_f="$TESTROOT/stderr"
    env HOME="$FAKE_HOME" \
        BLAHPD_LOCATION="$BLAHPD_LOCATION" \
        BLAHPD_CONFIG_LOCATION="$BLAHPD_LOCATION/etc/blah.config" \
        "$@" \
        "$BLAHPD_LOCATION/libexec/test_submit.sh" -c /bin/true \
        > "$out_f" 2> "$err_f"
    run_status=$?
    run_stdout=$(cat "$out_f")
    run_stderr=$(cat "$err_f")
}

testcase() {
    tests_run=$((tests_run + 1))
    echo "- $1"
}

# ---------------------------------------------------------------------------

testcase "no flag file: submission proceeds"
setup_sandbox
run_submit
assert_contains "$run_stdout" "SUBMIT_PROCEEDED" "should reach the body of the submit script"
assert_equals "$run_status" "0" "should exit 0 when no flag is present"
teardown_sandbox

testcase "flag file present: submission is refused"
setup_sandbox
echo "Cluster maintenance, back Tuesday" > "$FAKE_HOME/.ce_stop"
run_submit
assert_not_contains "$run_stdout" "SUBMIT_PROCEEDED" "should not reach the body of the submit script"
if [ "$run_status" -eq 0 ]; then
    fail "should exit non-zero so server.c takes the 'submission command failed' branch" \
         "status: $run_status"
fi
teardown_sandbox

testcase "refusal carries the 1ERROR prefix on stderr"
setup_sandbox
echo "Cluster maintenance, back Tuesday" > "$FAKE_HOME/.ce_stop"
run_submit
assert_contains "$run_stderr" "1ERROR:" "stderr should use the blahp 1ERROR convention"
teardown_sandbox

testcase "refusal carries the administrator's message"
setup_sandbox
echo "Cluster maintenance, back Tuesday" > "$FAKE_HOME/.ce_stop"
run_submit
assert_contains "$run_stderr" "Cluster maintenance, back Tuesday" \
    "the admin's message must reach stderr, since server.c puts it in HoldReason"
teardown_sandbox

testcase "empty flag file still yields a usable message"
setup_sandbox
: > "$FAKE_HOME/.ce_stop"
run_submit
assert_contains "$run_stderr" "1ERROR:" "an empty flag file must still refuse"
assert_contains "$run_stderr" "disabled" "an empty flag file must still explain itself"
teardown_sandbox

testcase "only the first line of the flag file is used"
setup_sandbox
printf 'first line only\nSECOND_LINE_LEAKED\n' > "$FAKE_HOME/.ce_stop"
run_submit
assert_contains "$run_stderr" "first line only" "should use the first line"
assert_not_contains "$run_stderr" "SECOND_LINE_LEAKED" \
    "a multi-line message would corrupt the single-line blahp result protocol"
teardown_sandbox

testcase "oversized message is truncated to 200 bytes"
setup_sandbox
python3 -c 'print("A" * 500)' > "$FAKE_HOME/.ce_stop"
run_submit
msg_len=$(printf '%s' "$run_stderr" | tr -cd 'A' | wc -c | tr -d ' ')
if [ "$msg_len" -gt 200 ]; then
    fail "message must be capped at 200 bytes to fit the 1024-byte HoldReason buffer" \
         "got $msg_len bytes of message"
fi
teardown_sandbox

testcase "control characters are stripped from the message"
setup_sandbox
printf 'clean\tmessage\r here\n' > "$FAKE_HOME/.ce_stop"
run_submit
if printf '%s' "$run_stderr" | grep -q '[[:cntrl:]]'; then
    fail "control characters must be stripped before reaching the result line" \
         "stderr: $(printf '%s' "$run_stderr" | cat -v)"
fi
teardown_sandbox

testcase "blah_stop_submission_file overrides the default path"
setup_sandbox
echo "relocated flag" > "$TESTROOT/elsewhere_stop"
run_submit blah_stop_submission_file="$TESTROOT/elsewhere_stop"
assert_contains "$run_stderr" "relocated flag" "the config override must be honoured"
assert_not_contains "$run_stdout" "SUBMIT_PROCEEDED" "override should still block"
teardown_sandbox

testcase "a flag at the default path is ignored when the override points elsewhere"
setup_sandbox
echo "should not be used" > "$FAKE_HOME/.ce_stop"
run_submit blah_stop_submission_file="$TESTROOT/absent_stop"
assert_contains "$run_stdout" "SUBMIT_PROCEEDED" \
    "with the override set to a missing file, submission should proceed"
teardown_sandbox

# kubernetes_submit.sh sources only blah_load_config.sh, so it bypasses
# bls_parse_submit_options and needs the check wired in explicitly. Only the
# blocked case is exercised: letting the real script through would try to reach
# a cluster.
testcase "kubernetes_submit.sh is blocked by the flag as well"
setup_sandbox
echo "kubernetes path blocked" > "$FAKE_HOME/.ce_stop"
env HOME="$FAKE_HOME" \
    BLAHPD_LOCATION="$BLAHPD_LOCATION" \
    BLAHPD_CONFIG_LOCATION="$BLAHPD_LOCATION/etc/blah.config" \
    "$BLAHPD_LOCATION/libexec/kubernetes_submit.sh" -c /bin/true \
    > "$TESTROOT/stdout" 2> "$TESTROOT/stderr"
run_status=$?
run_stderr=$(cat "$TESTROOT/stderr")
assert_contains "$run_stderr" "1ERROR:" "kubernetes_submit.sh must honour the flag"
assert_contains "$run_stderr" "kubernetes path blocked" "the admin's message must reach stderr"
if [ "$run_status" -eq 0 ]; then
    fail "kubernetes_submit.sh should exit non-zero when stopped" "status: $run_status"
fi
teardown_sandbox

# ---------------------------------------------------------------------------

echo
if [ "$tests_failed" -eq 0 ]; then
    echo "PASS: $tests_run tests"
    exit 0
else
    echo "FAIL: $tests_failed of $tests_run tests failed"
    exit 1
fi
