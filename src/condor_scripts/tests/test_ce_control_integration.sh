#!/bin/bash
#
# End-to-end test of the contract between the two halves of the red button.
#
# ce_control writes the stop flag; blah_common_submit_functions.sh reads it. The
# path and the message format are the only things they share, and they are
# duplicated in two files in two different subtrees. Every other test in this
# suite exercises one half in isolation and would stay green if one side drifted.
# This one drives ce_control for real and then runs a real blahp submit script
# against the flag it produced.
#
# Usage: ./test_ce_control_integration.sh
#

set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CE_CONTROL="$HERE/../ce_control"
BLAHP_SCRIPTS=$(cd "$HERE/../../blahp/src/scripts" && pwd)

tests_run=0
tests_failed=0

fail() {
    tests_failed=$((tests_failed + 1))
    echo "  FAIL: $1"
    [ $# -gt 1 ] && echo "$2" | sed 's/^/        /'
    return 0
}

testcase() { tests_run=$((tests_run + 1)); echo "- $1"; }

assert_contains() {
    case "$1" in
        *"$2"*) return 0 ;;
        *) fail "$3" "expected to contain: $2
actual: $1" ;;
    esac
}

setup() {
    TESTROOT=$(mktemp -d "${TMPDIR:-/tmp}/ceint.XXXXXX")
    FAKE_HOME="$TESTROOT/home"
    SHIMDIR="$TESTROOT/bin"
    BLAHPD_LOCATION="$FAKE_HOME/bosco/glite"
    mkdir -p "$FAKE_HOME/bosco/glite/etc" "$FAKE_HOME/bosco/glite/libexec" \
             "$FAKE_HOME/bosco/glite/bin" "$FAKE_HOME/bosco/glite/sbin" \
             "$FAKE_HOME/bosco/sandbox" "$SHIMDIR"

    ln -s "$BLAHP_SCRIPTS"/*.sh "$FAKE_HOME/bosco/glite/libexec/" 2>/dev/null

    cat > "$FAKE_HOME/bosco/glite/etc/condor_config.ft-gahp" <<EOF
BOSCO_SANDBOX_DIR=\$ENV(HOME)/bosco/sandbox
EOF
    printf 'slurm_binpath=%s\n' "$SHIMDIR" > "$FAKE_HOME/bosco/glite/etc/blah.config"

    : > "$TESTROOT/queue"
    printf '#!/bin/bash\ncut -d" " -f1 < %s/queue | grep . || true\n' "$TESTROOT" > "$SHIMDIR/squeue"
    printf '#!/bin/bash\n: > %s/queue\n' "$TESTROOT" > "$SHIMDIR/scancel"
    chmod +x "$SHIMDIR/squeue" "$SHIMDIR/scancel"

    # A stand-in for slurm_submit.sh: same two lines every real submit script runs.
    cat > "$FAKE_HOME/bosco/glite/libexec/test_submit.sh" <<'STUB'
#!/bin/bash
. `dirname $0`/blah_common_submit_functions.sh
bls_parse_submit_options "$@"
echo "SUBMIT_PROCEEDED"
STUB
    chmod +x "$FAKE_HOME/bosco/glite/libexec/test_submit.sh"
}

teardown() { [ -n "${TESTROOT:-}" ] && rm -rf "$TESTROOT"; }

run_ce_control() {
    env HOME="$FAKE_HOME" PATH="$SHIMDIR:$PATH" USER="${USER:-testuser}" \
        "$CE_CONTROL" "$@" > "$TESTROOT/cc.out" 2>&1
    cc_status=$?
    cc_out=$(cat "$TESTROOT/cc.out")
}

run_submit() {
    env HOME="$FAKE_HOME" \
        BLAHPD_LOCATION="$BLAHPD_LOCATION" \
        BLAHPD_CONFIG_LOCATION="$FAKE_HOME/bosco/glite/etc/blah.config" \
        "$FAKE_HOME/bosco/glite/libexec/test_submit.sh" -c /bin/true \
        > "$TESTROOT/s.out" 2> "$TESTROOT/s.err"
    submit_status=$?
    submit_out=$(cat "$TESTROOT/s.out")
    submit_err=$(cat "$TESTROOT/s.err")
}

# ---------------------------------------------------------------------------

testcase "before stop, the blahp accepts submissions"
setup
run_submit
assert_contains "$submit_out" "SUBMIT_PROCEEDED" "a running site must accept submissions"
teardown

testcase "ce_control stop makes the real blahp submit script refuse"
setup
run_ce_control stop -y -g 2 -m "Emergency stop by site admin"
run_submit
if [ "$submit_status" -eq 0 ]; then
    fail "the blahp must refuse after ce_control stop" \
         "ce_control said:
$cc_out
submit stdout: $submit_out"
fi
assert_contains "$submit_err" "1ERROR:" "the refusal must use the blahp error convention"
teardown

testcase "the admin's message survives from ce_control into the blahp refusal"
setup
run_ce_control stop -y -g 2 -m "Emergency stop by site admin"
run_submit
assert_contains "$submit_err" "Emergency stop by site admin" \
    "the message ce_control wrote must be the message the CE operator sees"
teardown

testcase "ce_control's default message also reaches the blahp"
setup
run_ce_control stop -y -g 2
run_submit
assert_contains "$submit_err" "1ERROR:" "a default message must still block"
assert_contains "$submit_err" "site administrator" "the default message must be intelligible"
teardown

testcase "ce_control resume lets submissions through again"
setup
run_ce_control stop -y -g 2 -m "brief pause"
run_submit
if [ "$submit_status" -eq 0 ]; then
    fail "precondition: stop should have blocked submission"
fi
run_ce_control resume -y
run_submit
assert_contains "$submit_out" "SUBMIT_PROCEEDED" "resume must restore submission"
teardown

testcase "ce_control lockout also leaves submissions blocked"
setup
mkdir -p "$FAKE_HOME/.ssh"
echo 'ssh-rsa AAAA1 ce@hosted' > "$FAKE_HOME/.ssh/authorized_keys"
run_ce_control lockout -y -g 2 -m "locked out"
run_submit
if [ "$submit_status" -eq 0 ]; then
    fail "lockout must block submission as well as ssh" "$cc_out"
fi
assert_contains "$submit_err" "locked out" "the lockout message must reach the CE"
teardown

# ---------------------------------------------------------------------------

echo
if [ "$tests_failed" -eq 0 ]; then
    echo "PASS: $tests_run tests"
    exit 0
else
    echo "FAIL: $tests_failed of $tests_run tests failed"
    exit 1
fi
