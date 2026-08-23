#!/usr/bin/env bash
# tests/test_unit.sh — unit tests for individual functions in cac_setup.sh.
#
# Usage:
#   test_unit.sh --list        emit test names (one per line)
#   test_unit.sh <test_name>   run a single test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

export CAC_SCRIPT="$(dirname "$SCRIPT_DIR")/cac_setup.sh"

# ---- tests -----------------------------------------------------------------

test_print_warn_outputs_tagged_line() {
    load_cac_functions
    local out
    out="$(print_warn "hello world" 2>&1)"
    assert_contains "$out" "[WARN]" "warn tag present"
    assert_contains "$out" "hello world" "message present"
}

test_print_err_outputs_tagged_line() {
    load_cac_functions
    local out
    out="$(print_err "boom" 2>&1)"
    assert_contains "$out" "[ERROR]" "error tag present"
    assert_contains "$out" "boom" "message present"
}

test_print_info_outputs_tagged_line() {
    load_cac_functions
    local out
    out="$(print_info "note" 2>&1)"
    assert_contains "$out" "[INFO]" "info tag present"
    assert_contains "$out" "note" "message present"
}

test_root_check_exits_when_not_root() {
    # We are a real non-root user in CI/dev; running the check directly must
    # exit 86 with the explanation. E_* codes live inside main(), set here.
    local out code
    out="$(load_cac_functions; E_NOTROOT=86 root_check 2>&1)"
    code=$?
    assert_exit_code 86 "$code"
    assert_contains "$out" "must run as root"
}

test_root_check_passes_when_root_euid() {
    # fakeroot makes EUID read as 0 inside its child, letting us exercise the
    # pass path without real privileges. fakeroot re-execs a fresh shell that
    # cannot inherit functions, so we run a fixture script instead. Skip if
    # fakeroot is unavailable.
    if ! command -v fakeroot >/dev/null; then
        echo "SKIP: fakeroot not installed"
        return 0
    fi
    local out code
    out="$(fakeroot bash "$SCRIPT_DIR/fixtures/root_check_child.sh" "$CAC_SCRIPT" 2>&1)"
    code=$?
    assert_exit_code 0 "$code"
}

test_stop_browser_ignores_already_dead_pid() {
    load_cac_functions
    stop_browser 4194303
    assert_exit_code 0 $?
}

test_stop_browser_terminates_spawned_process() {
    load_cac_functions
    sleep 30 &
    local pid=$!
    kill -0 "$pid" 2>/dev/null || { echo "failed to spawn sleeper"; exit 1; }
    stop_browser "$pid"
    if kill -0 "$pid" 2>/dev/null; then
        echo "process still alive after stop_browser"
        kill -9 "$pid" 2>/dev/null || true
        exit 1
    fi
}

test_import_certs_skips_when_no_certs_extracted() {
    make_stubs
    load_cac_functions
    DWNLD_DIR="$(mktemp -d)"
    CERT_FILENAME="AllCerts"
    CERT_EXTENSION="cer"
    EXIT_SUCCESS=0
    mkdir -p "$DWNLD_DIR/AllCerts"
    local db="$DWNLD_DIR/fake.profile/firefox/cert9.db"
    local out code
    out="$(import_certs "$db" 2>&1)"
    code=$?
    assert_exit_code 0 "$code"
    assert_contains "$out" "No .cer certificates found"
    local count
    count="$(stub_call_count certutil)"
    assert_equals "0" "$count" "certutil must not be invoked with no certs"
    remove_stubs
    rm -rf "$DWNLD_DIR"
}

test_import_certs_invokes_certutil_per_cert() {
    make_stubs
    load_cac_functions
    DWNLD_DIR="$(mktemp -d)"
    CERT_FILENAME="AllCerts"
    CERT_EXTENSION="cer"
    EXIT_SUCCESS=0
    mkdir -p "$DWNLD_DIR/AllCerts"
    printf "a" > "$DWNLD_DIR/AllCerts/CA1.cer"
    printf "b" > "$DWNLD_DIR/AllCerts/CA2.cer"
    local db="$DWNLD_DIR/fake.profile/firefox/cert9.db"
    local out code log count
    out="$(import_certs "$db" 2>&1)"
    code=$?
    assert_exit_code 0 "$code"
    count="$(stub_call_count certutil)"
    assert_equals "2" "$count" "certutil called once per .cer file"
    log="$(cat "$CALL_LOG")"
    assert_contains "$log" "-t TC" "trust flags used"
    remove_stubs
    rm -rf "$DWNLD_DIR"
}

test_browser_check_warns_when_no_browsers_found() {
    make_stubs
    load_cac_functions
    # Ensure neither browser is discoverable: build a restricted PATH holding
    # only the stub bin plus coreutils needed by assertions/cleanup.
    export SUDO_USER=testuser
    FAKE_HOME="$(mktemp -d)"
    export FAKE_HOME ORIG_HOME="$FAKE_HOME"
    # Minimal tool dir: symlink only the utilities browser_check's callees touch
    # (echo/printf are builtins; find/grep/dirname/xargs/cat are external).
    local min_bin
    min_bin="$(mktemp -d)"
    for tool in find grep dirname xargs cat rm; do
        ln -s "$(command -v "$tool")" "$min_bin/$tool"
    done
    local saved_path="$PATH"
    PATH="$STUB_BIN:$min_bin"
    hash -r
    # shellcheck disable=SC2034  # cleaned up after the assertion below
    MIN_BIN="$min_bin"
    # Vars normally initialized in main() before browser_check runs.
    DB_FILENAME="cert9.db"
    ORIG_HOME="$FAKE_HOME"
    ff_exists=false
    chrome_exists=false
    local out
    out="$(browser_check 2>&1)"
    local code=$?
    PATH="$saved_path"
    assert_exit_code 0 "$code"
    assert_contains "$out" "No version of Mozilla Firefox OR Google Chrome has been detected."
    assert_contains "$out" "[WARN]"
    remove_stubs
    rm -rf "$FAKE_HOME"
}

test_pin_values_are_set() {
    # EXPECTED_BUNDLE_SHA256* are assigned inside main(), so extract them from
    # the script source rather than relying on sourcing side effects.
    local pin date
    pin="$(grep -oP '^\s*EXPECTED_BUNDLE_SHA256="\K[0-9a-f]+' "$CAC_SCRIPT")"
    date="$(grep -oP '^\s*EXPECTED_BUNDLE_SHA256_DATE="\K[^"]+' "$CAC_SCRIPT")"
    assert_equals "64" "${#pin}" "digest is 64 hex chars"
    [ -n "$date" ] || { echo "pin date not configured"; exit 1; }
}

# ---- dispatch --------------------------------------------------------------

case "${1:-}" in
    --list)
        declare -F | awk '{print $3}' | grep '^test_' | sort
        ;;
    "")
        echo "usage: $0 <test_name> | --list"
        exit 2
        ;;
    *)
        if declare -F "$1" >/dev/null; then
            "$1"
        else
            echo "unknown test: $1"
            exit 2
        fi
        ;;
esac
