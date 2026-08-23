# Test Suite Guide

How to run and extend the test suite for `cac_setup.sh`.

## Requirements

- bash (the suite is pure bash — no bats, pytest, or other frameworks)
- fakeroot (optional; only needed for the root_check pass-path test — the suite skips that test gracefully if it's missing)

Check availability:

```bash
bash --version        # any modern bash works
command -v fakeroot   # optional
```

## Running the tests

From the repository root:

```bash
# Run the full suite
bash tests/run_tests.sh

# Run with verbose output (prints each passing test name)
bash tests/run_tests.sh -v
```

The runner exits 0 when everything passes, 1 on any failure — suitable for CI.

Expected output:

```
Results: 16 passed, 0 failed.
```

## Running a single test

Each test file doubles as a standalone runner. List what's available:

```bash
bash tests/test_unit.sh --list
bash tests/test_integration.sh --list
```

Run one test by name:

```bash
bash tests/test_unit.sh test_print_warn_outputs_tagged_line
bash tests/test_integration.sh test_main_happy_path_downloads_verifies_and_imports
```

A single test exits 0 on success, 1 on assertion failure, 2 if the name is unknown.

Useful while debugging a failure:

```bash
# See exactly where main() dies in an integration test
bash -x cac_setup.sh   # manual reproduction, stubs not applied
```

## What gets tested (and how)

The script under test does real-world things — downloads files, installs apt packages, talks to systemd. The suite never touches any of that. Instead:

- **Function loading**: tests source only the function definitions from `cac_setup.sh`, cutting the file off before its trailing `main` call (`tests/helpers.sh` → `load_cac_functions`).
- **Command stubs**: `make_stubs` puts fake executables at the front of `PATH`. Every stub logs its arguments to a file so assertions can verify "certutil was called exactly twice" or "wget got `-qP <dir>`". Stubs simulate success by default; failure modes are opt-in via environment variables.
- **Isolation**: every test runs in its own subshell with fresh stubs and temp directories, so no state leaks between tests.

Stub behavior switches (set as env vars before calling into the script):

| Variable | Effect |
|---|---|
| `WGET_STUB_FAIL=1` | wget exits nonzero, writes no bundle |
| `UNZIP_STUB_FAIL=1` | unzip exits nonzero |
| `SNAP_CONNECT_STUB_FAIL=1` | snap connect exits nonzero |
| `CERTUTIL_STUB_FAIL=1` | certutil exits nonzero |
| `SHA256SUM_STUB_DIGEST=<hex>` | sha256sum reports this digest instead of the pinned one |

Assertion helpers available in test files:

```bash
assert_equals "expected" "$actual" "optional failure message"
assert_contains "$haystack" "needle"          # substring match
assert_not_contains "$haystack" "needle"
assert_exit_code 0 "$code"                    # or omit code to use $?
```

Any assertion failure prints details and exits 1, which the runner reports as a failed test.

## Adding a new test

1. Pick the right file:
   - `tests/test_unit.sh` — one function in isolation.
   - `tests/test_integration.sh` — end-to-end `main()` flow with stubs.
2. Add a function named `test_<behavior_description>`:

```bash
test_my_new_behavior() {
    make_stubs                      # stub externals
    load_cac_functions              # define the script's functions

    # Arrange
    DWNLD_DIR="$(mktemp -d)"
    CERT_FILENAME="AllCerts"
    CERT_EXTENSION="cer"
    EXIT_SUCCESS=0
    mkdir -p "$DWNLD_DIR/AllCerts"

    # Act
    local out code
    out="$(import_certs "$DWNLD_DIR/fake.profile/firefox/cert9.db" 2>&1)"
    code=$?

    # Assert
    assert_exit_code 0 "$code"
    assert_contains "$out" "expected message"

    remove_stubs                    # always clean up
    rm -rf "$DWNLD_DIR"
}
```

That's it — the runner discovers it automatically on the next run. No registration lists to update.

### Tips

- Variables like `EXPECTED_BUNDLE_SHA256`, `E_NOTROOT`, and `DB_FILENAME` are assigned inside `main()`, so they don't exist after `load_cac_functions`. Set them yourself in the test, or grep them out of the script source (see `test_pin_values_are_set` for the grep approach).
- `EUID` is readonly in bash. To test root vs non-root paths, run the real script or a fixture under `fakeroot` (see `tests/fixtures/root_check_child.sh`) rather than trying to override `EUID`.
- If your test changes `PATH`, restore it (`hash -r` too) before asserting anything that shells out — leftover PATH state causes confusing "command not found" failures.
- The script runs under `set -euo pipefail`; unbound variables in your setup code will kill the test. Initialize everything you reference.

## CI

`.github/workflows/CI.yml` has a `test` job that installs fakeroot and runs `bash tests/run_tests.sh -v` on ubuntu-latest for every push and pull request. If your test needs another system package, add it to that job's install step.
