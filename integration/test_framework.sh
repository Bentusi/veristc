# test_framework.sh — shared test output library for VeriSTC run_*.sh scripts
# Source this file, do not execute directly.

# --- Internal state ---
_TF_PASS=0
_TF_FAIL=0

# --- Color detection ---
_tf_setup_colors() {
    if [ -t 1 ]; then
        _TF_C_GREEN=$'\033[32m'
        _TF_C_RED=$'\033[31m'
        _TF_C_YELLOW=$'\033[33m'
        _TF_C_BOLD=$'\033[1m'
        _TF_C_RESET=$'\033[0m'
    else
        _TF_C_GREEN=''
        _TF_C_RED=''
        _TF_C_YELLOW=''
        _TF_C_BOLD=''
        _TF_C_RESET=''
    fi
}
_tf_setup_colors

# --- Public functions ---

test_begin() {
    _TF_PASS=0
    _TF_FAIL=0
    echo "${_TF_C_BOLD}=== $1 ===${_TF_C_RESET}"
}

step() {
    echo "[$1] $2"
}

assert_ok() {
    local desc="$1"; shift
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "  ${desc} ... ${_TF_C_GREEN}OK${_TF_C_RESET}"
        _TF_PASS=$((_TF_PASS + 1))
    else
        echo "  ${desc} ... ${_TF_C_RED}FAIL (exit=${rc})${_TF_C_RESET}"
        _TF_FAIL=$((_TF_FAIL + 1))
    fi
}

assert_fail() {
    local desc="$1"; shift
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  ${desc} ... ${_TF_C_GREEN}OK (rejected)${_TF_C_RESET}"
        _TF_PASS=$((_TF_PASS + 1))
    else
        echo "  ${desc} ... ${_TF_C_RED}FAIL (expected rejection)${_TF_C_RESET}"
        _TF_FAIL=$((_TF_FAIL + 1))
    fi
}

assert_contains() {
    local file="$1" string="$2" desc="$3"
    if grep -Fq "$string" "$file" 2>/dev/null; then
        echo "  ${desc} ... ${_TF_C_GREEN}OK${_TF_C_RESET}"
        _TF_PASS=$((_TF_PASS + 1))
    else
        echo "  ${desc} ... ${_TF_C_RED}FAIL (not found: ${string})${_TF_C_RESET}"
        _TF_FAIL=$((_TF_FAIL + 1))
    fi
}

assert_not_contains() {
    local file="$1" string="$2" desc="$3"
    if grep -Fq "$string" "$file" 2>/dev/null; then
        echo "  ${desc} ... ${_TF_C_RED}FAIL (unexpectedly found: ${string})${_TF_C_RESET}"
        _TF_FAIL=$((_TF_FAIL + 1))
    else
        echo "  ${desc} ... ${_TF_C_GREEN}OK${_TF_C_RESET}"
        _TF_PASS=$((_TF_PASS + 1))
    fi
}

assert_line_count() {
    local file="$1" expected="$2" desc="$3"
    local actual
    actual=$(wc -l < "$file" 2>/dev/null)
    if [ "$actual" -eq "$expected" ] 2>/dev/null; then
        echo "  ${desc} ... ${_TF_C_GREEN}OK${_TF_C_RESET}"
        _TF_PASS=$((_TF_PASS + 1))
    else
        echo "  ${desc} ... ${_TF_C_RED}FAIL (expected ${expected} lines, got ${actual})${_TF_C_RESET}"
        _TF_FAIL=$((_TF_FAIL + 1))
    fi
}

assert_file_exists() {
    local file="$1" desc="$2"
    if [ -f "$file" ]; then
        echo "  ${desc} ... ${_TF_C_GREEN}OK${_TF_C_RESET}"
        _TF_PASS=$((_TF_PASS + 1))
    else
        echo "  ${desc} ... ${_TF_C_RED}FAIL (file not found: ${file})${_TF_C_RESET}"
        _TF_FAIL=$((_TF_FAIL + 1))
    fi
}

assert_exit_code() {
    local expected="$1" desc="$2"; shift 2
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq "$expected" ]; then
        echo "  ${desc} ... ${_TF_C_GREEN}OK${_TF_C_RESET}"
        _TF_PASS=$((_TF_PASS + 1))
    else
        echo "  ${desc} ... ${_TF_C_RED}FAIL (expected exit=${expected}, got exit=${rc})${_TF_C_RESET}"
        _TF_FAIL=$((_TF_FAIL + 1))
    fi
}

skip() {
    echo "${_TF_C_YELLOW}[SKIP] $1${_TF_C_RESET}"
}

summary_pass() {
    echo ""
    echo "${_TF_C_GREEN}PASS: $1${_TF_C_RESET}"
    exit 0
}

summary_fail() {
    echo ""
    echo "${_TF_C_RED}FAIL: $1${_TF_C_RESET}"
    exit 1
}

check_failures() {
    echo ""
    if [ "$_TF_FAIL" -gt 0 ]; then
        summary_fail "$1 (${_TF_FAIL} failure(s))"
    else
        summary_pass "$1 (${_TF_PASS} check(s) passed)"
    fi
}
# vim: set ft=bash :
