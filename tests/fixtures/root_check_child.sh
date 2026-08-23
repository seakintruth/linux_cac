#!/usr/bin/env bash
# tests/fixtures/root_check_child.sh
#
# Child process used by test_root_check_passes_when_root_euid: defines the
# cac_setup.sh functions (without running main) and invokes root_check.
# Run under fakeroot so EUID reads as 0.

CAC_SCRIPT="${1:?usage: root_check_child.sh <path-to-cac_setup.sh>}"
eval "$(awk '/^main$/{exit} {print}' "$CAC_SCRIPT")"
E_NOTROOT=86 root_check
