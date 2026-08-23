#!/usr/bin/env bash
# tests/test_integration.sh — end-to-end main() flow with stubbed externals.
#
# Usage:
#   test_integration.sh --list        emit test names
#   test_integration.sh <test_name>   run a single test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

export CAC_SCRIPT="$(dirname "$SCRIPT_DIR")/cac_setup.sh"

# Run cac_setup.sh's main() in a controlled subshell:
#   - fakeroot makes EUID read as 0 (pass root_check) unless RUN_AS_USER=1
#   - SUDO_USER=testuser so the getent stub resolves FAKE_HOME
run_main() {
    (
        export SUDO_USER=testuser
        export FAKE_HOME
        if [ "${RUN_AS_USER:-0}" = "1" ]; then
            bash "$CAC_SCRIPT"
        else
            fakeroot bash "$CAC_SCRIPT"
        fi
    ) 2>&1
}

# ---- tests -----------------------------------------------------------------

test_main_happy_path_downloads_verifies_and_imports() {
    make_stubs
    FAKE_HOME="$(mktemp -d)"
    mkdir -p "$FAKE_HOME/.mozilla/firefox/abc123.default"
    touch "$FAKE_HOME/.mozilla/firefox/abc123.default/cert9.db"

    local out code log
    out="$(run_main)"
    code=$?

    assert_exit_code 0 "$code"

    log="$(cat "$CALL_LOG")"
    assert_contains "$log" "wget -qP" "bundle downloaded"
    assert_contains "$log" "unzip" "bundle extracted"
    assert_contains "$log" "certutil" "certificates imported"
    assert_contains "$log" "-t TC" "trusted-CA flags used"
    assert_contains "$out" "Bundle integrity verified against pin dated 2026-08-23" \
        "digest match message shown"

    remove_stubs
    rm -rf "$FAKE_HOME"
}

test_main_warns_and_continues_when_download_fails() {
    make_stubs
    export WGET_STUB_FAIL=1
    FAKE_HOME="$(mktemp -d)"

    local out code log
    out="$(run_main)"
    code=$?

    # Script must NOT abort; it warns and finishes.
    assert_exit_code 0 "$code"
    assert_contains "$out" "Failed to download" "download failure warned"
    assert_contains "$out" "was not found" "missing bundle warned"

    log="$(cat "$CALL_LOG")"
    # Note: apt install lists 'unzip' as a package name; assert on extraction form.
    assert_not_contains "$log" "unzip -d" "unzip skipped when bundle missing"
    assert_not_contains "$log" "certutil" "no import attempted without bundle"

    remove_stubs
    rm -rf "$FAKE_HOME"
}

test_main_warns_but_continues_on_digest_mismatch() {
    make_stubs
    export SHA256SUM_STUB_DIGEST="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    FAKE_HOME="$(mktemp -d)"
    mkdir -p "$FAKE_HOME/.mozilla/firefox/abc123.default"
    touch "$FAKE_HOME/.mozilla/firefox/abc123.default/cert9.db"

    local out code log
    out="$(run_main)"
    code=$?

    # Mismatch is a warning, not an abort: import still proceeds.
    assert_exit_code 0 "$code"
    assert_contains "$out" "SHA256 mismatch" "mismatch warning shown"
    assert_contains "$out" "2026-08-23" "pin date displayed"
    assert_contains "$out" "deadbeef" "actual digest displayed"
    assert_contains "$out" "public.cyber.mil/pki-pke/" "verification pointer shown"

    log="$(cat "$CALL_LOG")"
    assert_contains "$log" "certutil" "import still proceeds after mismatch warning"

    remove_stubs
    rm -rf "$FAKE_HOME"
}

test_main_continues_without_import_when_no_databases() {
    make_stubs
    FAKE_HOME="$(mktemp -d)"
    # No cert9.db anywhere under FAKE_HOME.

    local out code log
    out="$(run_main)"
    code=$?

    assert_exit_code 0 "$code"
    assert_contains "$out" "No valid databases located" "no-db warning shown"

    log="$(cat "$CALL_LOG")"
    assert_not_contains "$log" "certutil" "certutil skipped with no databases"

    remove_stubs
    rm -rf "$FAKE_HOME"
}

test_main_exits_nonroot() {
    make_stubs
    FAKE_HOME="$(mktemp -d)"

    # Run as a normal user: expect exit 86 with the root explanation.
    local out code
    out="$(RUN_AS_USER=1 run_main)"
    code=$?
    assert_exit_code 86 "$code"
    assert_contains "$out" "must run as root"

    remove_stubs
    rm -rf "$FAKE_HOME"
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
