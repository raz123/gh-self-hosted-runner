#!/usr/bin/env bash
# Tests for setup-runner.sh — focuses on the pure functions and input validation.
set -euo pipefail

PASS=0
FAIL=0
TOTAL=0

# ── Helpers ──────────────────────────────────────────────────────────────────
# Source only the functions and constants we need (skip main, check_prereqs, etc.)
# We redefine the helpers to avoid side effects from sourcing the full script.

EXCLUDE_LABELS="^(ubuntu-.*|windows-.*|macos-.*|self-hosted)$"

parse_labels_from_yaml() {
    local all_labels=()
    while IFS= read -r line; do
        line="${line#*:}"
        line="${line//\"/}"
        line="${line//\'/}"
        line="${line//\[/}"
        line="${line//\]/}"
        IFS=',' read -ra parts <<< "$line"
        for part in "${parts[@]}"; do
            part="$(echo "$part" | xargs)"
            [[ -z "$part" ]] && continue
            if [[ ! "$part" =~ $EXCLUDE_LABELS ]]; then
                all_labels+=("$part")
            fi
        done
    done < <(grep -iE '^\s*-?\s*runs-on\s*:' | sed 's/"//g; s/\[//g; s/\]//g')

    if [[ ${#all_labels[@]} -eq 0 ]]; then
        return 0
    fi
    local IFS=','
    printf '%s\n' "${all_labels[@]}" | awk '!seen[$0]++' | paste -sd, -
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        printf '  ✓ %s\n' "$label"
    else
        FAIL=$((FAIL + 1))
        printf '  ✗ %s\n    expected: %s\n    actual:   %s\n' "$label" "$expected" "$actual"
    fi
}

assert_exit_code() {
    local label="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        printf '  ✓ %s (exit %s)\n' "$label" "$actual"
    else
        FAIL=$((FAIL + 1))
        printf '  ✗ %s\n    expected exit: %s, actual: %s\n' "$label" "$expected" "$actual"
    fi
}

# ── Test: parse_labels_from_yaml ─────────────────────────────────────────────
printf '\n── parse_labels_from_yaml ──\n'

# Flow sequence with mixed labels
result=$(echo 'runs-on: [self-hosted, linux, orfox-builder]' | parse_labels_from_yaml)
assert_eq "flow sequence excludes self-hosted" "linux,orfox-builder" "$result"

# Scalar string
result=$(echo 'runs-on: self-hosted' | parse_labels_from_yaml)
assert_eq "scalar self-hosted only → empty" "" "$result"

# GitHub-hosted labels only
result=$(echo 'runs-on: ubuntu-latest' | parse_labels_from_yaml)
assert_eq "ubuntu-latest excluded" "" "$result"

result=$(echo 'runs-on: ubuntu-22.04' | parse_labels_from_yaml)
assert_eq "ubuntu-22.04 excluded" "" "$result"

result=$(echo 'runs-on: macos-14' | parse_labels_from_yaml)
assert_eq "macos-14 excluded" "" "$result"

result=$(echo 'runs-on: windows-latest' | parse_labels_from_yaml)
assert_eq "windows-latest excluded" "" "$result"

# Custom labels with hosted
result=$(echo 'runs-on: [self-hosted, linux, my-custom-label]' | parse_labels_from_yaml)
assert_eq "custom label preserved" "linux,my-custom-label" "$result"

# Multiple runs-on lines (different jobs)
result=$(printf 'runs-on: [self-hosted, linux]\nruns-on: [self-hosted, gpu]\n' | parse_labels_from_yaml)
assert_eq "multiple runs-on lines merged" "linux,gpu" "$result"

# Deduplication
result=$(printf 'runs-on: [self-hosted, linux]\nruns-on: [self-hosted, linux]\n' | parse_labels_from_yaml)
assert_eq "duplicate labels deduped" "linux" "$result"

# Quoted values
result=$(echo 'runs-on: "self-hosted"' | parse_labels_from_yaml)
assert_eq "quoted self-hosted excluded" "" "$result"

result=$(echo "runs-on: 'self-hosted'" | parse_labels_from_yaml)
assert_eq "single-quoted self-hosted excluded" "" "$result"

# Empty input
result=$(echo '' | parse_labels_from_yaml)
assert_eq "empty input → empty output" "" "$result"

# No runs-on lines at all
result=$(echo 'name: CI' | parse_labels_from_yaml)
assert_eq "no runs-on lines → empty output" "" "$result"

# ── Test: bash 3.2 empty array safety ────────────────────────────────────────
printf '\n── bash 3.2 empty array safety ──\n'

# This should NOT crash with "unbound variable" under set -u
result=$(echo 'name: no-runs-on' | parse_labels_from_yaml 2>&1)
exit_code=$?
assert_exit_code "empty array doesn't crash" "0" "$exit_code"
assert_eq "empty array returns empty string" "" "$result"

# ── Test: GHR_NAME validation ────────────────────────────────────────────────
printf '\n── GHR_NAME validation ──\n'

# We test the regex directly since the validation is in main()
NAME_REGEX='^[a-zA-Z0-9_-]+$'

# Valid names
for name in "my-runner" "buildbox_01" "runner123" "test" "A-B_C"; do
    TOTAL=$((TOTAL + 1))
    if [[ "$name" =~ $NAME_REGEX ]]; then
        PASS=$((PASS + 1))
        printf '  ✓ valid name: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf '  ✗ should be valid: %s\n' "$name"
    fi
done

# Invalid names
for name in "my runner" "runner.name" "runner/name" "runner@host" "runner;rm -rf" 'runner"quote'; do
    TOTAL=$((TOTAL + 1))
    if [[ ! "$name" =~ $NAME_REGEX ]]; then
        PASS=$((PASS + 1))
        printf '  ✓ rejected invalid name: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf '  ✗ should be rejected: %s\n' "$name"
    fi
done

# ── Test: hostname stripping ─────────────────────────────────────────────────
printf '\n── hostname domain stripping ──\n'

# Simulate what the script does
result=$(echo "build-server.prod.internal" | cut -d. -f1)
assert_eq "strips domain from dotted hostname" "build-server" "$result"

result=$(echo "mikals-macbook" | cut -d. -f1)
assert_eq "plain hostname unchanged" "mikals-macbook" "$result"

result=$(echo "runner.local" | cut -d. -f1)
assert_eq "strips .local suffix" "runner" "$result"

# ── Test: real workflow YAML from target repo ────────────────────────────────
printf '\n── real workflow YAML (OrangeFox) ──\n'

# Simulated content from build-orange.yml line 31
result=$(echo '    runs-on: [self-hosted, linux, orfox-builder]' | parse_labels_from_yaml)
assert_eq "OrangeFox labels detected" "linux,orfox-builder" "$result"

# ── Test: unattended mode detection ──────────────────────────────────────────
printf '\n── unattended mode detection ──\n'

# Simulate: GHR_REPO set → unattended
GHR_REPO="owner/repo"
unattended=false
if [[ -n "${GHR_REPO:-}" ]]; then
    unattended=true
fi
assert_eq "GHR_REPO set → unattended=true" "true" "$unattended"

# Simulate: GHR_REPO unset → not unattended
unset GHR_REPO
unattended=false
if [[ -n "${GHR_REPO:-}" ]]; then
    unattended=true
fi
assert_eq "GHR_REPO unset → unattended=false" "false" "$unattended"

# ── Test: dry_run helper ──────────────────────────────────────────────────────
printf '\n── dry_run helper ──\n'

# When DRY_RUN=false, dry_run returns 0 (proceed)
DRY_RUN=false
dry_run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        printf '[dry-run] %s\n' "$*" >&2
        return 1
    fi
    return 0
}
if dry_run "test action"; then
    assert_eq "DRY_RUN=false → dry_run returns 0" "0" "0"
else
    assert_eq "DRY_RUN=false → dry_run returns 0" "0" "1"
fi

# When DRY_RUN=true, dry_run returns 1 (skip)
DRY_RUN=true
if dry_run "test action"; then
    assert_eq "DRY_RUN=true → dry_run returns 1" "1" "0"
else
    assert_eq "DRY_RUN=true → dry_run returns 1" "1" "1"
fi
DRY_RUN=false

# ── Test: debug helper ────────────────────────────────────────────────────────
printf '\n── debug helper ──\n'

DEBUG=false
debug() { [[ "$DEBUG" == "true" ]] && printf '[debug] %s\n' "$*" >&2; return 0; }

# When DEBUG=false, debug produces no output
result=$(debug "test message" 2>&1)
assert_eq "DEBUG=false → no output" "" "$result"

# When DEBUG=true, debug produces output
DEBUG=true
result=$(debug "test message" 2>&1)
assert_eq "DEBUG=true → outputs message" "[debug] test message" "$result"
DEBUG=false

# ── Test: CLI flag parsing ────────────────────────────────────────────────────
printf '\n── CLI flag parsing ──\n'

# --dry-run and -n set DRY_RUN
for arg in "--dry-run" "-n"; do
    DRY_RUN=false
    case "$arg" in
        --dry-run|-n) DRY_RUN=true ;;
    esac
    assert_eq "$arg sets DRY_RUN=true" "true" "$DRY_RUN"
done

# --debug and -v set DEBUG
for arg in "--debug" "-v"; do
    DEBUG=false
    case "$arg" in
        --debug|-v) DEBUG=true ;;
    esac
    assert_eq "$arg sets DEBUG=true" "true" "$DEBUG"
done

# Unknown option shows error
result=$(bash setup-runner.sh --bogus 2>&1 || true)
if echo "$result" | grep -q "Unknown option"; then
    assert_eq "unknown option shows error" "0" "0"
else
    assert_eq "unknown option shows error" "0" "1"
fi

# ── Test: non-interactive detection ───────────────────────────────────────────
printf '\n── non-interactive detection ──\n'

# Pipe input is not a TTY
result=$(echo "test" | bash -c '[[ -t 0 ]] && echo "tty" || echo "not-tty"' 2>&1)
assert_eq "pipe is not a TTY" "not-tty" "$result"

# ── Test: setup-runner.sh --help includes new flags ──────────────────────────
printf '\n── help text includes new flags ──\n'

help_output=$(bash setup-runner.sh --help 2>&1)
if echo "$help_output" | grep -q '\-\-dry-run'; then
    assert_eq "help includes --dry-run" "0" "0"
else
    assert_eq "help includes --dry-run" "0" "1"
fi
if echo "$help_output" | grep -q '\-\-debug'; then
    assert_eq "help includes --debug" "0" "0"
else
    assert_eq "help includes --debug" "0" "1"
fi

# ── Test: dry-run exits cleanly ───────────────────────────────────────────────
printf '\n── dry-run exits cleanly ──\n'

dry_run_output=$(GHR_REPO=raz123/OrangeFox-Recovery-Builder-2024 \
GHR_LABELS=linux,orfox-builder \
bash setup-runner.sh --dry-run 2>&1)
dry_run_exit=$?
assert_exit_code "dry-run exits 0" "0" "$dry_run_exit"
if echo "$dry_run_output" | grep -q '\[dry-run\]'; then
    assert_eq "dry-run shows dry-run markers" "0" "0"
else
    assert_eq "dry-run shows dry-run markers" "0" "1"
fi
# ── Summary ──────────────────────────────────────────────────────────────────
printf '\n══════════════════════════════════════\n'
printf 'Results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$TOTAL"
if [[ "$FAIL" -eq 0 ]]; then
    printf 'ALL TESTS PASSED ✓\n'
    exit 0
else
    printf 'TESTS FAILED ✗\n'
    exit 1
fi
