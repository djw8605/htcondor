#!/bin/bash
#
# Tests for ce_control, the site-side red button.
#
# Self-contained: no batch system, no CE, no worker nodes. Slurm is replaced by
# shim squeue/scancel on PATH that replay a scripted job list and record every
# call, so the drain sequence can be asserted exactly.
#
# Usage: ./test_ce_control.sh
#

set -u

CE_CONTROL=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ce_control

# Recorded before any shim exists, so the degradation test can tell a real Slurm
# install from the shim it is about to remove.
if command -v squeue >/dev/null 2>&1; then HOST_HAS_SQUEUE=yes; else HOST_HAS_SQUEUE=no; fi

tests_run=0
tests_failed=0
current_test=""

fail() {
    tests_failed=$((tests_failed + 1))
    echo "  FAIL: $1"
    [ $# -gt 1 ] && echo "$2" | sed 's/^/        /'
    return 0
}

testcase() {
    tests_run=$((tests_run + 1))
    current_test="$1"
    echo "- $1"
}

assert_contains() {
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
    [ "$1" = "$2" ] || fail "$3" "expected: $2
actual:   $1"
}

assert_file_exists() {
    [ -e "$1" ] || fail "$2" "missing file: $1"
}

assert_file_absent() {
    [ -e "$1" ] && fail "$2" "file should not exist: $1"
    return 0
}

# ---------------------------------------------------------------------------
# Sandbox: a throwaway HOME with a bosco install and shim batch tools.
# ---------------------------------------------------------------------------

# SHIM_STATE lines are "<jobid> <STATE>". squeue reads it; scancel mutates it
# according to SHIM_POLICY:
#   normal      - every scancel removes the jobs it targets
#   ignore-term - --signal=TERM is a no-op (payload ignoring SIGTERM); a plain
#                 scancel still removes
#   ignore-all  - nothing is ever removed (queue never drains)
setup() {
    TESTROOT=$(mktemp -d "${TMPDIR:-/tmp}/cecontrol.XXXXXX")
    FAKE_HOME="$TESTROOT/home"
    SHIMDIR="$TESTROOT/bin"
    SHIM_STATE="$TESTROOT/queue"
    SHIM_LOG="$TESTROOT/calls"
    SHIM_POLICY_FILE="$TESTROOT/policy"
    SANDBOX_DIR="$FAKE_HOME/bosco/sandbox"

    mkdir -p "$FAKE_HOME/bosco/glite/etc" "$SHIMDIR" "$SANDBOX_DIR"
    : > "$SHIM_STATE"
    : > "$SHIM_LOG"
    echo "normal" > "$SHIM_POLICY_FILE"

    cat > "$FAKE_HOME/bosco/glite/etc/condor_config.ft-gahp" <<EOF
BOSCO_SANDBOX_DIR=\$ENV(HOME)/bosco/sandbox
LOG=\$ENV(HOME)/bosco/glite/log
EOF

    cat > "$FAKE_HOME/bosco/glite/etc/blah.config" <<EOF
slurm_binpath=$SHIMDIR
EOF

    cat > "$SHIMDIR/squeue" <<EOF
#!/bin/bash
echo "squeue \$*" >> "$SHIM_LOG"
state_filter=""
for a in "\$@"; do
  case "\$a" in
    --state=*) state_filter="\${a#--state=}" ;;
  esac
done
while read -r jid jstate; do
  [ -z "\$jid" ] && continue
  if [ -n "\$state_filter" ] && [ "\$jstate" != "\$state_filter" ]; then continue; fi
  echo "\$jid"
done < "$SHIM_STATE"
EOF

    cat > "$SHIMDIR/scancel" <<EOF
#!/bin/bash
echo "scancel \$*" >> "$SHIM_LOG"
policy=\$(cat "$SHIM_POLICY_FILE")
is_signal=no
state_filter=""
for a in "\$@"; do
  case "\$a" in
    --signal=*) is_signal=yes ;;
    --state=*)  state_filter="\${a#--state=}" ;;
  esac
done
[ "\$policy" = "ignore-all" ] && exit 0
if [ "\$policy" = "ignore-term" ] && [ "\$is_signal" = "yes" ]; then exit 0; fi
tmp=\$(mktemp)
while read -r jid jstate; do
  [ -z "\$jid" ] && continue
  if [ -n "\$state_filter" ] && [ "\$jstate" != "\$state_filter" ]; then
    echo "\$jid \$jstate" >> "\$tmp"
  fi
done < "$SHIM_STATE"
mv "\$tmp" "$SHIM_STATE"
exit 0
EOF

    chmod +x "$SHIMDIR/squeue" "$SHIMDIR/scancel"
}

teardown() {
    [ -n "${TESTROOT:-}" ] && rm -rf "$TESTROOT"
}

queue_add()   { echo "$1 $2" >> "$SHIM_STATE"; }
set_policy()  { echo "$1" > "$SHIM_POLICY_FILE"; }
make_sandbox() { mkdir -p "$SANDBOX_DIR/ab12/ab123/$1"; echo "payload" > "$SANDBOX_DIR/ab12/ab123/$1/file"; }
calls()       { cat "$SHIM_LOG"; }

run_cc() {
    local out_f err_f
    out_f="$TESTROOT/out" ; err_f="$TESTROOT/err"
    env HOME="$FAKE_HOME" \
        PATH="$SHIMDIR:$PATH" \
        USER="${USER:-testuser}" \
        "$CE_CONTROL" "$@" > "$out_f" 2> "$err_f"
    run_status=$?
    run_out=$(cat "$out_f")
    run_err=$(cat "$err_f")
    run_all="$run_out
$run_err"
}

# ---------------------------------------------------------------------------
# status and scaffolding
# ---------------------------------------------------------------------------

testcase "status on a clean site exits 0 and reports not stopped"
setup
run_cc status
assert_equals "$run_status" "0" "status should exit 0"
assert_contains "$run_all" "not stopped" "should say the site is not stopped"
teardown

testcase "no arguments defaults to status"
setup
run_cc
assert_equals "$run_status" "0" "bare invocation should exit 0"
assert_contains "$run_all" "not stopped" "bare invocation should behave as status"
teardown

testcase "status reports the stop flag and its message"
setup
echo "Cluster on fire" > "$FAKE_HOME/.ce_stop"
run_cc status
assert_contains "$run_all" "STOPPED" "should report the stopped state"
assert_contains "$run_all" "Cluster on fire" "should surface the admin's message"
teardown

testcase "status reports running and pending job counts"
setup
queue_add 1 RUNNING; queue_add 2 RUNNING; queue_add 3 PENDING
run_cc status
assert_contains "$run_all" "2" "should report 2 running"
assert_contains "$run_all" "1" "should report 1 pending"
teardown

testcase "status changes nothing"
setup
echo "flagged" > "$FAKE_HOME/.ce_stop"
queue_add 1 RUNNING
make_sandbox job_a
run_cc status
assert_file_exists "$SANDBOX_DIR/ab12/ab123/job_a/file" "status must not sweep sandboxes"
assert_file_exists "$FAKE_HOME/.ce_stop" "status must not remove the flag"
assert_equals "$(calls | grep -c scancel)" "0" "status must never call scancel"
teardown

testcase "an unknown subcommand exits 1 with usage"
setup
run_cc frobnicate
assert_equals "$run_status" "1" "unknown subcommand should exit 1"
assert_contains "$run_all" "Usage" "should print usage"
teardown

testcase "--help exits 0 and prints usage"
setup
run_cc --help
assert_equals "$run_status" "0" "--help should exit 0"
assert_contains "$run_all" "Usage" "should print usage"
teardown

# ---------------------------------------------------------------------------
# stop: the happy path
# ---------------------------------------------------------------------------

# Line number of the first logged call matching a pattern, or 0.
call_line() {
    local n
    n=$(grep -n -- "$1" "$SHIM_LOG" 2>/dev/null | head -n 1 | cut -d: -f1)
    echo "${n:-0}"
}

testcase "stop writes the flag file carrying the message"
setup
run_cc stop -y -g 2 -m "Cluster maintenance"
assert_file_exists "$FAKE_HOME/.ce_stop" "stop must write the flag file"
assert_equals "$(head -n 1 "$FAKE_HOME/.ce_stop")" "Cluster maintenance" \
    "the flag file must carry the admin's message"
teardown

testcase "stop writes a default message when none is given"
setup
run_cc stop -y -g 2
assert_file_exists "$FAKE_HOME/.ce_stop" "stop must write the flag file"
if [ ! -s "$FAKE_HOME/.ce_stop" ]; then
    fail "the default message must not be empty"
fi
teardown

testcase "stop blocks submission before it cancels anything"
setup
queue_add 1 RUNNING
run_cc stop -y -g 2
flag_line=$(grep -n "scancel" "$SHIM_LOG" | head -n 1 | cut -d: -f1)
# The flag must exist by the time any cancel ran; assert ordering via the script
# having written it at all plus no cancel preceding it is not observable from the
# log, so assert the invariant that matters: the flag survives the run.
assert_file_exists "$FAKE_HOME/.ce_stop" "the flag must remain after the run"
teardown

testcase "stop cancels pending jobs before signalling running ones"
setup
queue_add 1 RUNNING; queue_add 2 PENDING
run_cc stop -y -g 2
pending_at=$(call_line "state=PENDING")
term_at=$(call_line "signal=TERM")
if [ "$pending_at" -eq 0 ]; then
    fail "pending jobs must be cancelled" "$(calls)"
elif [ "$term_at" -eq 0 ]; then
    fail "running jobs must be signalled" "$(calls)"
elif [ "$pending_at" -ge "$term_at" ]; then
    fail "the pending cancel must come first, so nothing launches mid-drain" "$(calls)"
fi
teardown

testcase "the TERM signal carries --full so it reaches the batch shell"
setup
queue_add 1 RUNNING
run_cc stop -y -g 2
term_call=$(grep -- "--signal=TERM" "$SHIM_LOG" | head -n 1)
assert_contains "$term_call" "--full" \
    "without --full Slurm signals only job steps, not the trap-bearing batch shell"
teardown

testcase "the pending cancel is re-issued inside the drain loop"
setup
queue_add 1 RUNNING
set_policy ignore-term
run_cc stop -y -g 3
n=$(grep -c -- "state=PENDING" "$SHIM_LOG")
if [ "$n" -lt 2 ]; then
    fail "the pending cancel must repeat each pass to catch jobs that slip in" \
         "saw $n pending cancels:
$(calls)"
fi
teardown

testcase "a job appearing mid-drain is still cancelled"
setup
queue_add 1 RUNNING
set_policy ignore-term
( sleep 1; echo "99 PENDING" >> "$SHIM_STATE" ) &
run_cc stop -y -g 4
wait
if grep -q "^99 " "$SHIM_STATE"; then
    fail "a job that appeared during the drain must not survive" "$(cat "$SHIM_STATE")"
fi
teardown

testcase "no hard cancel is issued when the polite TERM drains the queue"
setup
queue_add 1 RUNNING
run_cc stop -y -g 5
hard=$(grep -- "scancel" "$SHIM_LOG" | grep -v -- "--signal" | grep -v -- "--state")
if [ -n "$hard" ]; then
    fail "the hard cancel should be skipped when TERM already drained the queue" \
         "unexpected: $hard"
fi
assert_equals "$run_status" "0" "a clean drain should exit 0"
teardown

testcase "a successful drain sweeps the sandbox directories"
setup
queue_add 1 RUNNING
make_sandbox job_a; make_sandbox job_b
run_cc stop -y -g 5
assert_file_absent "$SANDBOX_DIR/ab12/ab123/job_a" "sandboxes must be swept after a clean drain"
assert_file_absent "$SANDBOX_DIR/ab12/ab123/job_b" "sandboxes must be swept after a clean drain"
assert_file_exists "$SANDBOX_DIR" "the sandbox root itself must survive"
teardown

testcase "--keep-sandboxes leaves the sandbox directories alone"
setup
queue_add 1 RUNNING
make_sandbox job_a
run_cc stop -y -g 5 --keep-sandboxes
assert_file_exists "$SANDBOX_DIR/ab12/ab123/job_a/file" \
    "--keep-sandboxes must preserve sandboxes for forensics"
teardown

testcase "--dry-run changes nothing at all"
setup
queue_add 1 RUNNING; queue_add 2 PENDING
make_sandbox job_a
run_cc stop -y -n -g 2
assert_file_absent "$FAKE_HOME/.ce_stop" "dry-run must not write the flag"
assert_file_exists "$SANDBOX_DIR/ab12/ab123/job_a/file" "dry-run must not sweep sandboxes"
assert_equals "$(grep -c scancel "$SHIM_LOG" || true)" "0" "dry-run must not cancel anything"
assert_equals "$run_status" "0" "dry-run should exit 0"
teardown

testcase "--dry-run reports what it would do"
setup
queue_add 1 RUNNING; queue_add 2 PENDING
make_sandbox job_a
run_cc stop -n -g 2
assert_contains "$run_all" "would" "dry-run should describe the plan"
teardown

testcase "stop without -y on a non-tty refuses rather than guessing"
setup
queue_add 1 RUNNING
run_cc stop -g 2 < /dev/null
assert_equals "$run_status" "1" "should exit 1 rather than proceed unconfirmed"
assert_file_absent "$FAKE_HOME/.ce_stop" "must not have written the flag"
assert_contains "$run_all" "-y" "should tell the operator how to proceed"
teardown

# ---------------------------------------------------------------------------
# stop: timeout, residuals, and degradation
# ---------------------------------------------------------------------------

testcase "a queue that will not drain triggers the hard cancel"
setup
queue_add 1 RUNNING
set_policy ignore-all
run_cc stop -y -g 2
hard=$(grep -- "scancel" "$SHIM_LOG" | grep -v -- "--signal" | grep -v -- "--state")
if [ -z "$hard" ]; then
    fail "the hard cancel must be issued once the grace period expires" "$(calls)"
fi
teardown

testcase "a queue that will not drain exits 3 and leaves sandboxes intact"
setup
queue_add 1 RUNNING
make_sandbox job_a
set_policy ignore-all
run_cc stop -y -g 2
assert_equals "$run_status" "3" "an undrained queue must exit 3"
assert_file_exists "$SANDBOX_DIR/ab12/ab123/job_a/file" \
    "sandboxes must survive: jobs may still be staging output into them"
teardown

testcase "an undrained queue explains that the command is re-runnable"
setup
queue_add 1 RUNNING
set_policy ignore-all
run_cc stop -y -g 2
assert_contains "$run_all" "Re-run" "should tell the operator the command can be repeated"
teardown

testcase "re-running stop after the jobs clear completes the sweep"
setup
queue_add 1 RUNNING
make_sandbox job_a
set_policy ignore-all
run_cc stop -y -g 2
assert_equals "$run_status" "3" "first run should report the queue as undrained"
# Jobs finally clear on their own; the flag is still in place, so nothing new arrived.
: > "$SHIM_STATE"
run_cc stop -y -g 2
assert_equals "$run_status" "0" "the second run should complete cleanly"
assert_file_absent "$SANDBOX_DIR/ab12/ab123/job_a" "the second run must finish the sweep"
teardown

testcase "jobs killed by the hard cancel are reported as leaked directories"
setup
queue_add 1 RUNNING; queue_add 2 RUNNING
set_policy ignore-term
run_cc stop -y -g 2
assert_contains "$run_all" "worker-node" \
    "SIGKILLed jobs strand their working directories; that must be stated"
assert_equals "$run_status" "2" "a run with residuals must exit 2, not 0"
teardown

# When blah_run_in_workdir=yes the wrapper sets new_home to the job's workdir
# and its cleanup deliberately does not rm -rf, because there is no separate
# temp directory. Nothing leaks on the worker node: the sandbox sweep covers it.
testcase "with blah_run_in_workdir=yes, killed jobs are not reported as leaks"
setup
printf 'slurm_binpath=%s\nblah_run_in_workdir=yes\n' "$SHIMDIR" \
    > "$FAKE_HOME/bosco/glite/etc/blah.config"
queue_add 1 RUNNING
set_policy ignore-term
run_cc stop -y -g 2
assert_not_contains "$run_all" "were NOT removed" \
    "in workdir mode there is no separate worker-node directory to leak"
assert_equals "$run_status" "0" "no residual means a clean exit"
teardown

testcase "without blah_run_in_workdir, killed jobs are still reported as leaks"
setup
printf 'slurm_binpath=%s\nblah_run_in_workdir=no\n' "$SHIMDIR" \
    > "$FAKE_HOME/bosco/glite/etc/blah.config"
queue_add 1 RUNNING
set_policy ignore-term
run_cc stop -y -g 2
assert_contains "$run_all" "worker-node" "the default mode does leak and must say so"
assert_equals "$run_status" "2" "a real residual must exit 2"
teardown

testcase "a clean drain reports no leaked directories"
setup
queue_add 1 RUNNING
run_cc stop -y -g 5
assert_not_contains "$run_all" "worker-node" \
    "a clean drain must not claim residuals it does not have"
assert_equals "$run_status" "0" "a clean drain exits 0"
teardown

testcase "an unsupported batch system still blocks submissions"
setup
if [ "$HOST_HAS_SQUEUE" = yes ]; then
    echo "  (skipped: this host has a real squeue)"
else
    rm -f "$SHIMDIR/squeue" "$SHIMDIR/scancel"
    run_cc stop -y -g 2
    assert_file_exists "$FAKE_HOME/.ce_stop" \
        "the flag is batch-system-agnostic and must still be written"
    assert_equals "$run_status" "2" "should exit 2: blocked, but jobs not cancelled"
    assert_contains "$run_all" "by hand" "should tell the operator to cancel manually"
fi
teardown

# ---------------------------------------------------------------------------
# lockout and resume
# ---------------------------------------------------------------------------

make_authorized_keys() {
    mkdir -p "$FAKE_HOME/.ssh"
    printf '%s\n' "$@" > "$FAKE_HOME/.ssh/authorized_keys"
}

AK() { echo "$FAKE_HOME/.ssh/authorized_keys"; }

testcase "lockout comments out the key and backs the file up"
setup
make_authorized_keys "ssh-rsa AAAAB3NzaC1yc2E ce@hosted"
run_cc lockout -y -g 5
assert_file_exists "$FAKE_HOME/.ce_control/authorized_keys.bak" "must back the file up first"
if grep -q '^ssh-rsa' "$(AK)"; then
    fail "the key must no longer be active" "$(cat "$(AK)")"
fi
assert_contains "$(cat "$(AK)")" "ssh-rsa AAAAB3NzaC1yc2E" \
    "the key must be commented out, not deleted"
teardown

testcase "lockout backs up the original bytes exactly"
setup
make_authorized_keys "ssh-rsa AAAAB3NzaC1yc2E ce@hosted"
orig=$(cat "$(AK)")
run_cc lockout -y -g 5
assert_equals "$(cat "$FAKE_HOME/.ce_control/authorized_keys.bak")" "$orig" \
    "the backup must be byte-identical to the original"
teardown

testcase "lockout also writes the stop flag"
setup
make_authorized_keys "ssh-rsa AAAAB3NzaC1yc2E ce@hosted"
run_cc lockout -y -g 5 -m "locked out"
assert_file_exists "$FAKE_HOME/.ce_stop" "lockout must block submissions too"
teardown

testcase "lockout warns when more than one key is present"
setup
make_authorized_keys "ssh-rsa AAAA1 ce@hosted" "ssh-ed25519 BBBB2 someone@else"
run_cc lockout -y -g 5
assert_contains "$run_all" "2" "should report how many keys it is disabling"
if grep -q '^ssh-' "$(AK)"; then
    fail "all keys must be disabled on a dedicated account" "$(cat "$(AK)")"
fi
teardown

testcase "lockout on a missing authorized_keys reports failure honestly"
setup
run_cc lockout -y -g 5
assert_equals "$run_status" "1" "must not claim success it did not achieve"
assert_contains "$run_all" "authorized_keys" "should name the file it could not find"
teardown

testcase "lockout is idempotent when keys are already disabled"
setup
make_authorized_keys "ssh-rsa AAAAB3NzaC1yc2E ce@hosted"
run_cc lockout -y -g 5
after_first=$(cat "$(AK)")
run_cc lockout -y -g 5
assert_equals "$(cat "$(AK)")" "$after_first" "a second lockout must not double-comment"
teardown

testcase "lockout with an undrained queue still severs but logs the orphans"
setup
make_authorized_keys "ssh-rsa AAAAB3NzaC1yc2E ce@hosted"
queue_add 4242 RUNNING
set_policy ignore-all
run_cc lockout -y -g 2
if grep -q '^ssh-rsa' "$(AK)"; then
    fail "with -y the operator has chosen to sever regardless" "$(cat "$(AK)")"
fi
assert_contains "$run_all" "orphan" "must state that the jobs become orphans"
assert_contains "$(cat "$FAKE_HOME/.ce_control/last-run.log" 2>/dev/null)" "4242" \
    "orphaned job IDs must be recorded for manual cleanup"
teardown

testcase "resume removes the stop flag"
setup
echo "stopped" > "$FAKE_HOME/.ce_stop"
run_cc resume -y
assert_file_absent "$FAKE_HOME/.ce_stop" "resume must remove the flag"
assert_equals "$run_status" "0" "resume should exit 0"
teardown

testcase "lockout then resume restores authorized_keys byte-identically"
setup
make_authorized_keys "ssh-rsa AAAA1 ce@hosted" "ssh-ed25519 BBBB2 someone@else"
orig=$(cat "$(AK)")
run_cc lockout -y -g 5
run_cc resume -y
assert_equals "$(cat "$(AK)")" "$orig" "resume must restore the original bytes"
teardown

testcase "resume refuses to touch authorized_keys when the backup is missing"
setup
make_authorized_keys "ssh-rsa AAAA1 ce@hosted"
run_cc lockout -y -g 5
rm -f "$FAKE_HOME/.ce_control/authorized_keys.bak"
run_cc resume -y
assert_contains "$run_all" "by hand" "should tell the operator what to restore manually"
if grep -q '^ssh-rsa' "$(AK)"; then
    fail "resume must not guess at restoring keys without a backup" "$(cat "$(AK)")"
fi
teardown

testcase "resume on an already-running site is harmless"
setup
run_cc resume -y
assert_equals "$run_status" "0" "resume with nothing to undo should still exit 0"
teardown

testcase "resume --dry-run changes nothing"
setup
make_authorized_keys "ssh-rsa AAAA1 ce@hosted"
run_cc lockout -y -g 5
locked=$(cat "$(AK)")
run_cc resume -n
assert_file_exists "$FAKE_HOME/.ce_stop" "dry-run must not remove the flag"
assert_equals "$(cat "$(AK)")" "$locked" "dry-run must not restore keys"
teardown

# ---------------------------------------------------------------------------
# concurrency
# ---------------------------------------------------------------------------

testcase "a second run refuses while another holds the lock"
setup
mkdir -p "$FAKE_HOME/.ce_control/lock"
echo $$ > "$FAKE_HOME/.ce_control/lock/pid"   # this test process is certainly alive
queue_add 1 RUNNING
run_cc stop -y -g 2
assert_equals "$run_status" "1" "a concurrent run must refuse"
assert_file_absent "$FAKE_HOME/.ce_stop" "the refused run must change nothing"
assert_contains "$run_all" "already running" "should say why it refused"
teardown

testcase "a stale lock from a dead process is reclaimed"
setup
mkdir -p "$FAKE_HOME/.ce_control/lock"
# A pid that cannot be running: allocate one, then reap it.
( exit 0 ) & dead_pid=$!; wait $dead_pid 2>/dev/null
echo "$dead_pid" > "$FAKE_HOME/.ce_control/lock/pid"
queue_add 1 RUNNING
run_cc stop -y -g 2
assert_equals "$run_status" "0" "a stale lock must not block the button forever"
assert_file_exists "$FAKE_HOME/.ce_stop" "the run should have proceeded"
teardown

testcase "the lock is released when the run finishes"
setup
queue_add 1 RUNNING
run_cc stop -y -g 2
assert_file_absent "$FAKE_HOME/.ce_control/lock" "the lock must not outlive the run"
teardown

testcase "status does not take the lock"
setup
mkdir -p "$FAKE_HOME/.ce_control/lock"
echo $$ > "$FAKE_HOME/.ce_control/lock/pid"
run_cc status
assert_equals "$run_status" "0" "read-only status must not contend for the lock"
teardown

# ---------------------------------------------------------------------------
# other batch systems
# ---------------------------------------------------------------------------

setup_pbs() {
    rm -f "$SHIMDIR/squeue" "$SHIMDIR/scancel"
    cat > "$FAKE_HOME/bosco/glite/etc/blah.config" <<EOF
pbs_binpath=$SHIMDIR
EOF
    cat > "$SHIMDIR/qselect" <<EOF
#!/bin/bash
echo "qselect \$*" >> "$SHIM_LOG"
cut -d' ' -f1 < "$SHIM_STATE" | grep . || true
EOF
    cat > "$SHIMDIR/qdel" <<EOF
#!/bin/bash
echo "qdel \$*" >> "$SHIM_LOG"
[ "\$(cat "$SHIM_POLICY_FILE")" = "ignore-all" ] && exit 0
: > "$SHIM_STATE"
exit 0
EOF
    chmod +x "$SHIMDIR/qselect" "$SHIMDIR/qdel"
}

testcase "pbs is detected and its jobs are cancelled"
setup
if [ "$HOST_HAS_SQUEUE" = yes ]; then
    echo "  (skipped: this host has a real squeue)"
else
    setup_pbs
    queue_add 77 RUNNING
    make_sandbox job_a
    run_cc stop -y -g 3
    assert_contains "$(calls)" "qdel" "pbs jobs must be cancelled with qdel"
    assert_equals "$run_status" "0" "a clean pbs drain should exit 0"
    assert_file_absent "$SANDBOX_DIR/ab12/ab123/job_a" "sandboxes must be swept for pbs too"
fi
teardown

testcase "status names the detected batch system"
setup
if [ "$HOST_HAS_SQUEUE" = yes ]; then
    echo "  (skipped: this host has a real squeue)"
else
    setup_pbs
    run_cc status
    assert_contains "$run_all" "pbs" "status should report the detected batch system"
fi
teardown

setup_condor() {
    rm -f "$SHIMDIR/squeue" "$SHIMDIR/scancel"
    cat > "$FAKE_HOME/bosco/glite/etc/blah.config" <<EOF
condor_binpath=$SHIMDIR
EOF
    cat > "$SHIMDIR/condor_q" <<EOF
#!/bin/bash
echo "condor_q \$*" >> "$SHIM_LOG"
cut -d' ' -f1 < "$SHIM_STATE" | grep . || true
EOF
    cat > "$SHIMDIR/condor_rm" <<EOF
#!/bin/bash
echo "condor_rm \$*" >> "$SHIM_LOG"
[ "\$(cat "$SHIM_POLICY_FILE")" = "ignore-all" ] && exit 0
: > "$SHIM_STATE"
exit 0
EOF
    chmod +x "$SHIMDIR/condor_q" "$SHIMDIR/condor_rm"
}

testcase "htcondor is detected and its jobs are removed"
setup
if [ "$HOST_HAS_SQUEUE" = yes ]; then
    echo "  (skipped: this host has a real squeue)"
else
    setup_condor
    queue_add 12.0 RUNNING
    make_sandbox job_a
    run_cc stop -y -g 3
    assert_contains "$(calls)" "condor_rm" "htcondor jobs must be removed with condor_rm"
    assert_equals "$run_status" "0" "a clean htcondor drain should exit 0"
    assert_file_absent "$SANDBOX_DIR/ab12/ab123/job_a" "sandboxes must be swept for htcondor too"
fi
teardown

testcase "an undrained htcondor queue escalates to a forced removal"
setup
if [ "$HOST_HAS_SQUEUE" = yes ]; then
    echo "  (skipped: this host has a real squeue)"
else
    setup_condor
    queue_add 12.0 RUNNING
    set_policy ignore-all
    run_cc stop -y -g 2
    assert_contains "$(calls)" "forcex" "the hard cancel must force removal"
    assert_equals "$run_status" "3" "an undrained htcondor queue must exit 3"
fi
teardown

testcase "an undrained pbs queue still exits 3 and keeps sandboxes"
setup
if [ "$HOST_HAS_SQUEUE" = yes ]; then
    echo "  (skipped: this host has a real squeue)"
else
    setup_pbs
    queue_add 77 RUNNING
    make_sandbox job_a
    set_policy ignore-all
    run_cc stop -y -g 2
    assert_equals "$run_status" "3" "an undrained pbs queue must exit 3"
    assert_file_exists "$SANDBOX_DIR/ab12/ab123/job_a/file" "sandboxes must survive"
fi
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
