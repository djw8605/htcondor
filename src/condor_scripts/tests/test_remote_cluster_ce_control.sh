#!/bin/bash
#
# Tests for the ce_control pieces of condor_remote_cluster: planting the button
# on the remote cluster, and refusing to quietly reinstall over a site that has
# pressed it.
#
# The helpers under test live between marker comments in condor_remote_cluster
# and are extracted and sourced here. condor_remote_cluster has no main() guard,
# so it cannot be sourced whole without running an install.
#
# ssh and scp are shimmed on PATH, so no remote host is needed.
#
# Usage: ./test_remote_cluster_ce_control.sh
#

set -u

SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REMOTE_CLUSTER="$SCRIPTS_DIR/condor_remote_cluster"

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

assert_not_contains() {
    case "$1" in
        *"$2"*) fail "$3" "expected NOT to contain: $2
actual: $1" ;;
        *) return 0 ;;
    esac
}

# Pull the marked helper block out of condor_remote_cluster and source it.
load_helpers() {
    local extracted="$TESTROOT/helpers.sh"
    awk '/BEGIN ce_control helpers/{f=1;next} /END ce_control helpers/{f=0} f' \
        "$REMOTE_CLUSTER" > "$extracted"
    if [ ! -s "$extracted" ]; then
        return 1
    fi
    # shellcheck disable=SC1090
    . "$extracted"
    return 0
}

setup() {
    TESTROOT=$(mktemp -d "${TMPDIR:-/tmp}/rcce.XXXXXX")
    SHIMDIR="$TESTROOT/bin"
    REMOTE_ROOT="$TESTROOT/remote"     # stands in for the remote home directory
    SHIM_LOG="$TESTROOT/calls"
    mkdir -p "$SHIMDIR" "$REMOTE_ROOT"
    : > "$SHIM_LOG"

    # ssh shim: runs the remote command against REMOTE_ROOT as if it were $HOME.
    cat > "$SHIMDIR/ssh" <<EOF
#!/bin/bash
args=("\$@")
cmd="\${args[\${#args[@]}-1]}"
echo "ssh \$*" >> "$SHIM_LOG"
HOME="$REMOTE_ROOT" bash -c "\$cmd"
EOF

    # scp shim: last argument is host:path; copy into REMOTE_ROOT.
    cat > "$SHIMDIR/scp" <<EOF
#!/bin/bash
echo "scp \$*" >> "$SHIM_LOG"
args=("\$@")
dest="\${args[\${#args[@]}-1]}"
src="\${args[\${#args[@]}-2]}"
path="\${dest#*:}"
[ -z "\$path" ] && path=.
mkdir -p "$REMOTE_ROOT/\$(dirname "\$path")" 2>/dev/null
cp "\$src" "$REMOTE_ROOT/\$path"
EOF

    chmod +x "$SHIMDIR/ssh" "$SHIMDIR/scp"
    PATH="$SHIMDIR:$PATH"

    # condor_remote_cluster's helpers reference these.
    ssh_control_path="$TESTROOT/control.%r@%h:%p"
    remote_host="testhost"
}

teardown() { [ -n "${TESTROOT:-}" ] && rm -rf "$TESTROOT"; PATH="$ORIG_PATH"; }

ORIG_PATH="$PATH"

# ---------------------------------------------------------------------------

testcase "the helper block is present and loadable"
setup
if load_helpers; then
    : # loaded
else
    fail "condor_remote_cluster must define the ce_control helpers between markers"
fi
teardown

testcase "install_ce_control places the button in the remote home directory"
setup
if load_helpers; then
    install_ce_control "$remote_host" "$SCRIPTS_DIR/ce_control" >/dev/null 2>&1
    if [ ! -f "$REMOTE_ROOT/ce_control" ]; then
        fail "ce_control must be installed into the remote home directory" "$(cat "$SHIM_LOG")"
    fi
else
    fail "helpers did not load"
fi
teardown

testcase "the button is installed outside ~/bosco, where rsync --delete cannot reach"
setup
if load_helpers; then
    install_ce_control "$remote_host" "$SCRIPTS_DIR/ce_control" >/dev/null 2>&1
    dest=$(grep '^scp ' "$SHIM_LOG" | tail -n 1)
    assert_not_contains "$dest" "bosco/" \
        "installing inside ~/bosco would be deleted by the next --delete push"
else
    fail "helpers did not load"
fi
teardown

testcase "the installed button is executable"
setup
if load_helpers; then
    install_ce_control "$remote_host" "$SCRIPTS_DIR/ce_control" >/dev/null 2>&1
    if [ ! -x "$REMOTE_ROOT/ce_control" ]; then
        fail "the button must be executable on arrival" "$(cat "$SHIM_LOG")"
    fi
else
    fail "helpers did not load"
fi
teardown

testcase "warn_if_ce_stopped is silent on a site that has not stopped"
setup
if load_helpers; then
    out=$(warn_if_ce_stopped "$remote_host" 2>&1)
    assert_not_contains "$out" "WARNING" "no warning is due when the site has not pressed the button"
else
    fail "helpers did not load"
fi
teardown

testcase "warn_if_ce_stopped warns when the remote site has stopped this CE"
setup
if load_helpers; then
    echo "Cluster maintenance, do not reinstall" > "$REMOTE_ROOT/.ce_stop"
    out=$(warn_if_ce_stopped "$remote_host" 2>&1)
    assert_contains "$out" "WARNING" "an installer must not quietly overwrite a stopped site"
    assert_contains "$out" "Cluster maintenance, do not reinstall" \
        "the site administrator's reason must be shown to whoever is installing"
else
    fail "helpers did not load"
fi
teardown

testcase "warn_if_ce_stopped still warns when the flag file is empty"
setup
if load_helpers; then
    : > "$REMOTE_ROOT/.ce_stop"
    out=$(warn_if_ce_stopped "$remote_host" 2>&1)
    assert_contains "$out" "WARNING" "an empty flag is still a stopped site"
else
    fail "helpers did not load"
fi
teardown

testcase "warn_if_ce_stopped names the flag file so it can be found and removed"
setup
if load_helpers; then
    echo "stopped" > "$REMOTE_ROOT/.ce_stop"
    out=$(warn_if_ce_stopped "$remote_host" 2>&1)
    assert_contains "$out" ".ce_stop" "the warning should name the flag file"
else
    fail "helpers did not load"
fi
teardown

# A defined-but-never-called helper would pass every test above while doing
# nothing. These check the install flow actually reaches them. Structural rather
# than behavioural, because driving the full installer needs a real cluster.
body_outside_helpers() {
    awk '/BEGIN ce_control helpers/{f=1} /END ce_control helpers/{f=0;next} !f' "$REMOTE_CLUSTER"
}

testcase "the install flow calls install_ce_control"
setup
if body_outside_helpers | grep -q 'install_ce_control'; then
    :
else
    fail "install_ce_control is defined but never invoked; the button would never be planted"
fi
teardown

testcase "the install flow calls warn_if_ce_stopped"
setup
if body_outside_helpers | grep -q 'warn_if_ce_stopped'; then
    :
else
    fail "warn_if_ce_stopped is defined but never invoked; a stopped site would be overwritten silently"
fi
teardown

testcase "the stopped-site check runs before the install rsync"
setup
warn_line=$(body_outside_helpers | grep -n 'warn_if_ce_stopped' | head -n 1 | cut -d: -f1)
rsync_line=$(body_outside_helpers | grep -n 'rsync --delete' | head -n 1 | cut -d: -f1)
if [ -z "$warn_line" ] || [ -z "$rsync_line" ]; then
    fail "expected both a warn_if_ce_stopped call and the install rsync"
elif [ "$warn_line" -ge "$rsync_line" ]; then
    fail "the warning must come before the install, not after it" \
         "warn at $warn_line, rsync at $rsync_line"
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
