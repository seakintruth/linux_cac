#!/usr/bin/env bash
# tests/helpers.sh
#
# Shared scaffolding sourced by every test case file. Provides:
#   - load_cac_functions : define cac_setup.sh functions without running main()
#   - make_stubs         : put stub commands on PATH and record their calls
#   - assert_* helpers (re-exported from run_tests.sh via duplication here so
#     each isolated subshell has them)

# ---- assertion helpers (kept in sync with run_tests.sh) ----
# Also exported so test case files can use them directly.

assert_equals() {
    if [ "$1" != "$2" ]
    then
        echo "assert_equals failed${3:+: $3}"
        echo "  expected: [$1]"
        echo "  actual:   [$2]"
        exit 1
    fi
}

assert_contains() {
    case "$1" in
        *"$2"*) return 0 ;;
        *)
            echo "assert_contains failed${3:+: $3}"
            echo "  haystack: [$1]"
            echo "  needle:   [$2]"
            exit 1
            ;;
    esac
}

assert_not_contains() {
    if [[ "$1" == *"$2"* ]]
    then
        echo "assert_not_contains failed${3:+: $3}"
        echo "  haystack must not contain: [$2]"
        exit 1
    fi
}

assert_exit_code() {
    # assert_exit_code <expected_code> [actual_code]
    local expected="$1"
    local actual="${2:-$?}"
    if [ "$expected" != "$actual" ]
    then
        echo "assert_exit_code failed: expected $expected, got $actual"
        exit 1
    fi
}

# ---- loading the script under test ----

# Define every function from cac_setup.sh in the current shell WITHOUT running
# main(). Works by cutting the file at its final bare `main` invocation.
load_cac_functions() {
    local cac_script="${CAC_SCRIPT:?CAC_SCRIPT must point at cac_setup.sh}"
    eval "$(awk '/^main$/{exit} {print}' "$cac_script")"
}

# ---- external command stubs ----

STUB_BIN=""
CALL_LOG=""

# Install stub executables on PATH. Each stub appends "cmd args..." to
# $CALL_LOG and performs a configurable behavior:
#
#   WGET_STUB_FAIL=1        -> wget exits nonzero, writes no file
#   UNZIP_STUB_FAIL=1       -> unzip exits nonzero
#   SNAP_CONNECT_STUB_FAIL=1-> snap connect exits nonzero
#   CERTUTIL_STUB_FAIL=1    -> certutil exits nonzero
#
# Everything else succeeds silently. `sleep` is stubbed to a no-op so tests
# that exercise stop_browser/run_firefox don't take real seconds.
make_stubs() {
    STUB_BIN="$(mktemp -d)"
    CALL_LOG="$(mktemp)"
    export CALL_LOG

    for cmd in wget apt systemctl snap certutil sudo pkcs11-register modutil getent sha256sum unzip awk find grep cut dirname xargs mapfile; do
        # Only stub what we override; leave real binaries otherwise.
        :
    done

    _write_stub wget '
        echo "wget $*" >> "$CALL_LOG"
        if [ "${WGET_STUB_FAIL:-0}" = "1" ]; then exit 7; fi
        # Simulate successful download: create the bundle file in -P dir.
        # Handles both "-qP DIR" (combined) and "-q -P DIR" forms.
        local dir="" url="" args=()
        while [ $# -gt 0 ]; do
            case "$1" in
                -qP|-P) dir="$2"; shift 2 ;;
                -q) shift ;;
                *) args+=("$1"); shift ;;
            esac
        done
        url="${args[-1]:-}"
        if [ -n "$dir" ]; then
            mkdir -p "$dir"
            printf "stub-bundle-content" > "$dir/AllCerts.zip"
        fi
    '

    _write_stub unzip '
        echo "unzip $*" >> "$CALL_LOG"
        if [ "${UNZIP_STUB_FAIL:-0}" = "1" ]; then exit 9; fi
        # Extract: create a couple of .cer files in target dir.
        local target=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -d) target="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        if [ -n "$target" ]; then
            mkdir -p "$target"
            printf "cert-a" > "$target/DoD_Root_CA_1.cer"
            printf "cert-b" > "$target/DoD_Root_CA_2.cer"
        fi
    '

    _write_stub sha256sum '
        echo "sha256sum $*" >> "$CALL_LOG"
        # Deterministic digest keyed off content so match/mismatch is testable.
        if [ "${SHA256SUM_STUB_DIGEST:-}" != "" ]; then
            echo "$SHA256SUM_STUB_DIGEST"
            exit 0
        fi
        echo "b07b90789c2f39db77ca26a30926851a708ee615f2235235f09867841badfacc"
    '

    _write_stub certutil '
        echo "certutil $*" >> "$CALL_LOG"
        if [ "${CERTUTIL_STUB_FAIL:-0}" = "1" ]; then exit 11; fi
    '

    _write_stub apt 'echo "apt $*" >> "$CALL_LOG"'
    _write_stub systemctl 'echo "systemctl $*" >> "$CALL_LOG"'
    _write_stub snap '
        echo "snap $*" >> "$CALL_LOG"
        if [ "${SNAP_CONNECT_STUB_FAIL:-0}" = "1" ]; then exit 13; fi
    '
    _write_stub sudo 'echo "sudo $*" >> "$CALL_LOG"'
    _write_stub pkcs11-register 'echo "pkcs11-register $*" >> "$CALL_LOG"'
    _write_stub modutil 'echo "modutil $*" >> "$CALL_LOG"'
    _write_stub sleep 'echo "sleep $*" >> "$CALL_LOG"'
    # getent must resolve SUDO_USER to a home dir for ORIG_HOME.
    _write_stub getent '
        echo "getent $*" >> "$CALL_LOG"
        case "$*" in
            *testuser*) echo "testuser:x:1000:1000::${FAKE_HOME:-/home/testuser}:/bin/bash" ;;
        esac
    '
    # kill must understand `kill -0 pid` liveness probes used by stop_browser.
    # Real kill works fine in tests since we spawn real background procs.

    export PATH="$STUB_BIN:$PATH"
}

_write_stub() {
    # _write_stub <name> <body>
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$STUB_BIN/$1"
    chmod +x "$STUB_BIN/$1"
}

remove_stubs() {
    [ -n "$STUB_BIN" ] && rm -rf "$STUB_BIN"
    [ -n "$CALL_LOG" ] && rm -f "$CALL_LOG"
}

# Read back everything a given stub command recorded.
stub_calls() {
    grep "^$1 " "$CALL_LOG" 2>/dev/null || true
}

# Count recorded invocations of a stub.
stub_call_count() {
    stub_calls "$1" | wc -l
}
