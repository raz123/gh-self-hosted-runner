#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# GitHub Self-Hosted Runner Setup — Universal, interactive, single-file script.
# Works on Linux (systemd) and macOS (launchd). Uses gh CLI for auth & API.
# ──────────────────────────────────────────────────────────────────────────────

VERSION="1.7.0"
GITHUB_API="https://api.github.com"
RUNNER_RELEASES_URL="https://api.github.com/repos/actions/runner/releases/latest"
GITHUB_DOWNLOAD="https://github.com/actions/runner/releases/download"
RUNNER_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/gh-runner"

# Labels to exclude from auto-detection (GitHub-hosted runners)
EXCLUDE_LABELS="^(ubuntu-.*|windows-.*|macos-.*|self-hosted)$"

# ── Color helpers ─────────────────────────────────────────────────────────────
info()    { printf '\033[1;34m→ %s\033[0m\n' "$*" >&2; }
warn()    { printf '\033[1;33m⚠ %s\033[0m\n' "$*" >&2; }
error()   { printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; }
success() { printf '\033[1;32m✔ %s\033[0m\n' "$*" >&2; }

# Debug & dry-run
DEBUG=false
DRY_RUN=false
debug()    { [[ "$DEBUG" == "true" ]] && printf '\033[1;90m  [debug] %s\033[0m\n' "$*" >&2; return 0; }
dry_run()  {
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[dry-run] $*"
        return 1  # caller uses || to skip
    fi
    return 0  # caller proceeds
}

# ── YAML label parser ────────────────────────────────────────────────────────
# Reads YAML text from stdin, extracts runs-on: values, excludes hosted labels,
# deduplicates, outputs comma-separated.
parse_labels_from_yaml() {
    # Collect all runs-on lines (handles flow sequences like [a, b] and scalars)
    local all_labels=()
    while IFS= read -r line; do
        # Strip leading/trailing whitespace and common YAML prefixes
        line="${line#*:}"
        line="${line//\"/}"
        line="${line//\'/}"
        line="${line//\[/}"
        line="${line//\]/}"
        IFS=',' read -ra parts <<< "$line"
        for part in "${parts[@]}"; do
            part="$(echo "$part" | xargs)"  # trim whitespace
            [[ -z "$part" ]] && continue
            # Skip GitHub-hosted labels
            if [[ ! "$part" =~ $EXCLUDE_LABELS ]]; then
                all_labels+=("$part")
            fi
        done
    done < <(grep -iE '^\s*-?\s*runs-on\s*:' | sed 's/"//g; s/\[//g; s/\]//g')

    # Deduplicate while preserving order (bash 3 compatible — use awk)
    if [[ ${#all_labels[@]} -eq 0 ]]; then
        return 0
    fi
    local IFS=','
    printf '%s\n' "${all_labels[@]}" | awk '!seen[$0]++' | paste -sd, -

}

# ── Phase 1: Prerequisites ───────────────────────────────────────────────────
check_prereqs() {
    debug "check_prereqs: starting"
    info "Checking prerequisites..."

    # gh CLI
    if ! command -v gh &>/dev/null; then
        error "gh CLI not found. Install: https://cli.github.com"
        exit 1
    fi
    if ! gh auth status &>/dev/null; then
        error "gh CLI not authenticated. Run: gh auth login"
        exit 1
    fi
    success "gh CLI authenticated"

    # Required tools
    for cmd in curl tar jq; do
        if ! command -v "$cmd" &>/dev/null; then
            error "$cmd not found. Please install it first."
            exit 1
        fi
    done
    success "curl, tar, jq found"

    # Detect OS
    local uname_s
    uname_s="$(uname -s)"
    case "$uname_s" in
        Linux)  RUNNER_PLATFORM="linux" ;;
        Darwin) RUNNER_PLATFORM="osx"   ;;
        *)
            error "Unsupported OS: $uname_s"
            exit 1
            ;;
    esac
    success "Detected OS: $uname_s → platform=$RUNNER_PLATFORM"

    # Detect arch
    local uname_m
    uname_m="$(uname -m)"
    case "$uname_m" in
        x86_64)  RUNNER_ARCH="x64"  ;;
        arm64|aarch64) RUNNER_ARCH="arm64" ;;
        *)
            error "Unsupported architecture: $uname_m"
            exit 1
            ;;
    esac
    success "Detected arch: $uname_m → arch=$RUNNER_ARCH"

    # Detect service manager
    RUNNER_SVC="none"
    if [[ "$RUNNER_PLATFORM" == "linux" ]]; then
        if command -v systemctl &>/dev/null && systemctl is-system-running &>/dev/null 2>&1; then
            RUNNER_SVC="systemd"
        fi
    elif [[ "$RUNNER_PLATFORM" == "osx" ]]; then
        if command -v launchctl &>/dev/null; then
            RUNNER_SVC="launchd"
        fi
    fi
    if [[ "$RUNNER_SVC" == "none" ]]; then
        warn "No systemd or launchd detected."
    fi
}

# ── Phase 2: Repo selection ──────────────────────────────────────────────────
select_repo() {
    if [[ -n "${GHR_REPO:-}" ]]; then
        info "Using repo from env: $GHR_REPO"
        return 0
    fi

    debug "select_repo: listing repos"
    info "Fetching repositories with admin access..."
    local repos
    repos="$(gh api user/repos --paginate --jq '.[] | select(.permissions.admin == true) | .full_name' 2>/dev/null || true)"

    if [[ -z "$repos" ]]; then
        error "No repositories found with admin access. Check gh auth and permissions."
        exit 1
    fi

    # Check workflow counts in parallel
    info "Checking workflow counts..."
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    local max_jobs=10
    local running=0
    while IFS= read -r repo; do
        (
            local count
            count="$(gh api "repos/${repo}/actions/workflows" --jq '.total_count' 2>/dev/null || echo "?")"
            echo "${count}|${repo}"
        ) > "${tmpdir}/${repo//\//_}" &
        running=$((running + 1))
        if (( running >= max_jobs )); then
            wait 2>/dev/null || true
            running=$((running - 1))
        fi
    done <<< "$repos"
    wait 2>/dev/null || true

    # Collect and sort results (repos with workflows first, then by count desc)
    local sorted_repos=()
    while IFS= read -r result; do
        sorted_repos+=("$result")
    done < <(
        for f in "$tmpdir"/*; do
            [[ -f "$f" ]] && cat "$f"
        done | sort -t'|' -k1 -rn
    )

    rm -rf "$tmpdir"
    trap - RETURN

    if [[ ${#sorted_repos[@]} -eq 0 ]]; then
        error "Failed to fetch repository data."
        exit 1
    fi
    debug "select_repo: found ${#sorted_repos[@]} repos"

    # Build menu
    info "Select a repository:"
    local menu_items=()
    for entry in "${sorted_repos[@]}"; do
        local count="${entry%%|*}"
        local repo="${entry#*|}"
        if [[ "$count" == "?" || "$count" == "0" ]]; then
            menu_items+=("${repo} (no workflows)")
        else
            menu_items+=("${repo} (${count} workflows)")
        fi
    done

    local choice
    if command -v fzf &>/dev/null; then
        choice="$(printf '%s\n' "${menu_items[@]}" | fzf --height=15 --reverse --prompt="Select repo: " | sed 's/ (.*//')"
    else
        if [[ -t 0 ]]; then
            PS3="Pick a repo (number): "
            select opt in "${menu_items[@]}"; do
                if [[ -n "$opt" ]]; then
                    choice="${opt%% (*}"
                    break
                fi
                warn "Invalid selection. Try again."
            done
        else
            error "No terminal available for interactive selection."
            error "Set GHR_REPO env var for non-interactive mode."
            exit 1
        fi
    fi

    if [[ -z "$choice" ]]; then
        error "No repository selected."
        exit 1
    fi

    GHR_REPO="$choice"
    success "Selected: $GHR_REPO"
}

# ── Phase 3: Label detection ─────────────────────────────────────────────────
detect_labels() {
    if [[ -n "${GHR_LABELS:-}" ]]; then
        info "Using labels from env: $GHR_LABELS"
        return 0
    fi

    debug "detect_labels: fetching workflows for $GHR_REPO"
    info "Detecting runner labels from workflows..."

    local detected_labels=""
    local workflow_files
    workflow_files="$(gh api "repos/${GHR_REPO}/contents/.github/workflows" --jq '.[].path' 2>/dev/null || true)"
    debug "detect_labels: found workflow files: $workflow_files"

    if [[ -z "$workflow_files" ]]; then
        if [[ "${GHR_UNATTENDED:-false}" == "true" ]]; then
            error "No workflow files found. Set GHR_LABELS env var for unattended mode."
            exit 1
        fi
        warn "No workflow files found in $GHR_REPO."
        if [[ -t 0 ]]; then
            info "Enter runner labels (comma-separated, e.g. self-hosted,linux): "
            read -r GHR_LABELS 2>/dev/null || true
        else
            error "No self-hosted runner labels found and stdin is not a terminal."
            error "Set GHR_LABELS env var for non-interactive mode."
            exit 1
        fi
        if [[ -z "$GHR_LABELS" ]]; then
            error "No labels provided."
            exit 1
        fi
        success "Labels: $GHR_LABELS"
        return 0
    fi

    local all_content=""
    while IFS= read -r wf_path; do
        [[ -z "$wf_path" ]] && continue
        local content
        content="$(gh api "repos/${GHR_REPO}/contents/${wf_path}" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)"
        all_content+=$'\n'"$content"
    done <<< "$workflow_files"

    detected_labels="$(echo "$all_content" | parse_labels_from_yaml)"
    debug "detect_labels: parsed labels: $detected_labels"

    # If no custom labels found, check if workflow uses bare "self-hosted"
    # and fall back to platform defaults (self-hosted + platform label)
    if [[ -z "$detected_labels" ]]; then
        if echo "$all_content" | grep -qiE 'runs-on\s*:\s*.*self-hosted'; then
            detected_labels="self-hosted,${RUNNER_PLATFORM}"
            debug "detect_labels: bare self-hosted found, using defaults: $detected_labels"
        fi
    fi

    if [[ -z "$detected_labels" ]]; then
        if [[ "${GHR_UNATTENDED:-false}" == "true" ]]; then
            error "No self-hosted runner labels found. Set GHR_LABELS env var for unattended mode."
            exit 1
        fi
        warn "No self-hosted runner labels found in workflows."
        if [[ -t 0 ]]; then
            info "Enter runner labels (comma-separated, e.g. self-hosted,linux): "
            read -r GHR_LABELS 2>/dev/null || true
        else
            error "No self-hosted runner labels found and stdin is not a terminal."
            error "Set GHR_LABELS env var for non-interactive mode."
            exit 1
        fi
        if [[ -z "$GHR_LABELS" ]]; then
            error "No labels provided."
            exit 1
        fi
    else
        if [[ "${GHR_UNATTENDED:-false}" == "true" ]]; then
            GHR_LABELS="$detected_labels"
            info "Auto-detected labels: $GHR_LABELS"
        else
            info "Auto-detected labels: $detected_labels"
            if [[ -t 0 ]]; then
                info "Press Enter to accept, or type new labels (comma-separated): "
                if read -r user_input 2>/dev/null; then
                    GHR_LABELS="${user_input:-$detected_labels}"
                else
                    # stdin hit EOF (piped curl|bash) — use detected labels
                    GHR_LABELS="$detected_labels"
                fi
            else
                GHR_LABELS="$detected_labels"
                info "Non-interactive: using auto-detected labels"
            fi
        fi
    fi

    success "Labels: $GHR_LABELS"
}

# ── Phase 4: Install & register ──────────────────────────────────────────────
install_runner() {
    debug "install_runner: GHR_DIR=$GHR_DIR"
    info "Installing runner to $GHR_DIR..."

    # Create directory
    if [[ -d "$GHR_DIR/.runner" ]] && [[ "${GHR_REPLACE:-true}" != "true" ]]; then
        error "Runner already installed at $GHR_DIR. Use --replace to overwrite or --uninstall first."
        exit 1
    fi
    if dry_run "Would create directory: $GHR_DIR"; then
        if ! mkdir -p "$GHR_DIR" 2>/dev/null; then
            error "Cannot create $GHR_DIR — check permissions."
            error "Fix: set GHR_DIR to a writable path:"
            error "  GHR_DIR=~/my-runners $0"
            exit 1
        fi
    fi
    # Remove existing runner config before re-configuration (needed for --replace idempotency)
    if [[ -f "$GHR_DIR/.runner" ]] && [[ "${GHR_REPLACE:-true}" == "true" ]]; then
        info "Removing existing runner configuration..."
        cd "$GHR_DIR"
        # Kill any running runner processes in this directory
        local running_pid
        running_pid="$(pgrep -f "$GHR_DIR/bin/Runner" 2>/dev/null || true)"
        if [[ -n "$running_pid" ]]; then
            info "Stopping existing runner process (PID: $running_pid)..."
            kill "$running_pid" 2>/dev/null || true
            sleep 2
            kill -9 "$running_pid" 2>/dev/null || true
        fi
        # Stop user-level systemd service if it exists
        systemctl --user stop "actions-runner-${GHR_NAME}.service" 2>/dev/null || true
        systemctl --user disable "actions-runner-${GHR_NAME}.service" 2>/dev/null || true
        rm -f ~/Library/LaunchAgents/actions.runner.*.${GHR_NAME}.plist 2>/dev/null || true
        # Try config.sh remove, then forcibly clean up local files
        if [[ -f "config.sh" ]]; then
            local removal_token
            removal_token="$(gh api "repos/${GHR_REPO}/actions/runners/remove-token" -X POST --jq '.token' 2>/dev/null || true)"
            if [[ -n "$removal_token" ]]; then
                ./config.sh remove --token "$removal_token" 2>/dev/null || true
            fi
        fi
        # Forcibly remove local config so config.sh won't refuse to reconfigure
        rm -f .runner .credentials .credentials_rsaparams .env .path
        cd - >/dev/null
    fi

    # Generate registration token
    local runner_token=""
    if dry_run "Would generate registration token for ${GHR_REPO}"; then
        info "Generating registration token..."
        runner_token="$(gh api "repos/${GHR_REPO}/actions/runners/registration-token" -X POST --jq '.token' 2>/dev/null)" || {
            error "Cannot generate registration token for $GHR_REPO."
            error "Ensure you have admin (not just write) access."
            exit 1
        }
        if [[ -z "$runner_token" ]]; then
            error "Empty registration token received."
            exit 1
        fi
    fi

    # Download latest runner (with local cache)
    local latest_tag latest_version runner_file cache_file
    if dry_run "Would fetch latest runner release and download"; then
        info "Fetching latest runner release..."
        latest_tag="$(curl -sfL "$RUNNER_RELEASES_URL" | jq -r '.tag_name')" || {
            error "Failed to fetch runner release info. Check network connection."
            error "URL: $RUNNER_RELEASES_URL"
            exit 1
        }
        latest_version="${latest_tag#v}"
        runner_file="actions-runner-${RUNNER_PLATFORM}-${RUNNER_ARCH}-${latest_version}.tar.gz"
        cache_file="${RUNNER_CACHE_DIR}/${runner_file}"
        debug "install_runner: runner archive $runner_file"

        # Check local cache first, then GHR_DIR, then download
        if [[ -f "$cache_file" ]]; then
            info "Using cached runner archive."
            cp "$cache_file" "$GHR_DIR/$runner_file"
        elif [[ -f "$GHR_DIR/$runner_file" ]]; then
            info "Runner archive found in install dir."
        else
            mkdir -p "$RUNNER_CACHE_DIR"
            info "Downloading $runner_file..."
            curl -sL "${GITHUB_DOWNLOAD}/${latest_tag}/${runner_file}" -o "$cache_file" || {
                error "Download failed: ${GITHUB_DOWNLOAD}/${latest_tag}/${runner_file}"
                exit 1
            }
            cp "$cache_file" "$GHR_DIR/$runner_file"
        fi

        info "Extracting runner..."
        tar xzf "$GHR_DIR/$runner_file" -C "$GHR_DIR" || {
            error "Failed to extract runner archive."
            exit 1
        }
        rm -f "$GHR_DIR/$runner_file"
    fi

    # Configure runner
    debug "install_runner: configuring runner"
    local replace_flag=""
    if [[ "${GHR_REPLACE:-true}" == "true" ]]; then
        replace_flag="--replace"
    fi
    if dry_run "Would configure runner for ${GHR_REPO} with name ${GHR_NAME}"; then
        info "Configuring runner..."
        cd "$GHR_DIR"
        ./config.sh \
            --url "https://github.com/${GHR_REPO}" \
            --token "$runner_token" \
            --name "$GHR_NAME" \
            --labels "$GHR_LABELS" \
            --work "$GHR_WORK" \
            --unattended \
            $replace_flag || {
            error "Runner config.sh failed. Check logs above for details."
            error "Common causes: token expired, repo name typo, insufficient permissions."
            exit 1
        }
    fi

    # Install service (only if --service flag was passed)
    if [[ "${GHR_SERVICE:-false}" == "true" ]]; then
        debug "install_runner: installing service"
        if dry_run "Would install and start service (${RUNNER_SVC})"; then
            info "Installing as service..."
            if [[ "$RUNNER_PLATFORM" == "linux" ]]; then
                _create_systemd_user_unit
            elif [[ "$RUNNER_PLATFORM" == "osx" ]]; then
                ./svc.sh install && ./svc.sh start || {
                    warn "svc.sh failed. Runner is configured but not running as a service."
                }
            fi
        fi
    fi

    success "Runner installed!"
    printf '\n'

    # Interactive prompt: launch the runner now?
    # Use /dev/tty (always the terminal, even with curl|bash pipes)
    if [[ "${GHR_SERVICE:-false}" != "true" ]]; then
        local launch_choice=""
        printf '\033[1;34m→ Launch the runner now? [Y/n]: \033[0m' >&2
        if read -r launch_choice </dev/tty 2>/dev/null; then
            launch_choice="${launch_choice,,}"  # lowercase
        fi
        if [[ "$launch_choice" != "n" && "$launch_choice" != "no" ]]; then
            if [[ -r "$GHR_DIR/run.sh" ]]; then
                info "Starting runner... (Ctrl+C to stop)"
                cd "$GHR_DIR"
                exec ./run.sh
            fi
        fi
    fi

    info "To run the runner later:"
    info "  cd $GHR_DIR && ./run.sh"
}

_create_systemd_user_unit() {
    local unit_dir="${HOME}/.config/systemd/user"
    local unit_file="${unit_dir}/actions-runner-${GHR_NAME}.service"
    local log_file="${GHR_DIR}/runner.log"

    mkdir -p "$unit_dir"
    cat > "$unit_file" << UNIT
[Unit]
Description=GitHub Actions Runner (${GHR_REPO})
After=network.target

[Service]
Type=simple
WorkingDirectory=${GHR_DIR}
ExecStart=${GHR_DIR}/run.sh
Restart=on-failure
RestartSec=5
StandardOutput=append:${log_file}
StandardError=append:${log_file}

[Install]
WantedBy=default.target
UNIT

    if systemctl --user daemon-reload 2>/dev/null && \
       systemctl --user enable "actions-runner-${GHR_NAME}.service" 2>/dev/null && \
       systemctl --user start "actions-runner-${GHR_NAME}.service" 2>/dev/null; then
        success "Systemd user service installed and started"
        info "To auto-start on login: loginctl enable-linger $(whoami)"
    else
        warn "Systemd user service failed. Runner is configured but not running as a service."
    fi
}

# ── Phase 5: Verify ──────────────────────────────────────────────────────────
verify_runner() {
    debug "verify_runner: checking status"
    info "Verifying runner status..."
    sleep 3

    local svc_ok=false

    # Check service status if --service was used
    if [[ "${GHR_SERVICE:-false}" == "true" ]]; then
        if [[ "$RUNNER_PLATFORM" == "linux" ]]; then
            local unit="actions.runner.$(echo "$GHR_REPO" | tr '/' '-').${GHR_NAME}.service"
            if systemctl is-active "$unit" &>/dev/null 2>&1; then
                svc_ok=true
            fi
            if [[ "$svc_ok" == "false" ]]; then
                local user_unit="actions-runner-${GHR_NAME}.service"
                if systemctl --user is-active "$user_unit" &>/dev/null 2>&1; then
                    svc_ok=true
                fi
            fi
        elif [[ "$RUNNER_PLATFORM" == "osx" && "$RUNNER_SVC" == "launchd" ]]; then
            if launchctl list 2>/dev/null | grep -q "actions.runner"; then
                svc_ok=true
            fi
        fi

        if [[ "$svc_ok" == "false" ]]; then
            warn "Runner service not detected. It may still be starting up."
        fi
    fi

    # API check
    local runner_info
    runner_info="$(gh api "repos/${GHR_REPO}/actions/runners" 2>/dev/null | \
        jq --arg name "$GHR_NAME" \
           '.runners[] | select(.name == $name) | {name: .name, status: .status, labels: [.labels[].name]}' 2>/dev/null || true)"
    if [[ -n "$runner_info" ]]; then
        local runner_status
        runner_status="$(echo "$runner_info" | jq -r '.status')"
        local runner_labels
        runner_labels="$(echo "$runner_info" | jq -r '.labels | join(", ")')"

        if [[ "$runner_status" == "online" ]]; then
            success "Runner '${GHR_NAME}' is ONLINE"
        else
            warn "Runner '${GHR_NAME}' status: ${runner_status}"
        fi

        printf '  Repo:   %s\n' "$GHR_REPO"
        printf '  Labels: %s\n' "$runner_labels"
        printf '  Manage: https://github.com/%s/settings/actions/runners\n' "$GHR_REPO"
    else
        warn "Runner not yet visible via API. It may take a moment to come online."
        info "Check: https://github.com/${GHR_REPO}/settings/actions/runners"
    fi
}

# ── Phase 6: Uninstall ───────────────────────────────────────────────────────
uninstall_runner() {
    debug "uninstall_runner: generating removal token"
    info "Uninstalling runner from $GHR_REPO..."

    # Generate removal token
    local removal_token
    removal_token="$(gh api "repos/${GHR_REPO}/actions/runners/remove-token" -X POST --jq '.token' 2>/dev/null)" || {
        error "Cannot generate removal token for $GHR_REPO."
        error "Ensure you have admin access. Token generation requires admin scope."
        exit 1
    }

    # Stop and uninstall service
    if [[ -d "$GHR_DIR" ]]; then
        cd "$GHR_DIR"

        # Stop user-level systemd service
        systemctl --user stop "actions-runner-${GHR_NAME}.service" 2>/dev/null || true
        systemctl --user disable "actions-runner-${GHR_NAME}.service" 2>/dev/null || true
        rm -f ~/Library/LaunchAgents/actions.runner.*.${GHR_NAME}.plist 2>/dev/null || true

        # Remove runner config
        if [[ -f "config.sh" ]]; then
            if dry_run "Would remove runner config via config.sh"; then
                ./config.sh remove --token "$removal_token" 2>/dev/null || {
                    warn "config.sh remove failed. Falling back to API deletion."
                }
            fi
        fi
    fi

    # Fallback: API deletion if runner still exists
    local runner_id
    runner_id="$(gh api "repos/${GHR_REPO}/actions/runners" 2>/dev/null | \
        jq --arg name "$GHR_NAME" \
           '.runners[] | select(.name == $name) | .id' 2>/dev/null || true)"
    if [[ -n "$runner_id" ]]; then
        info "Removing runner via API (ID: $runner_id)..."
        if dry_run "Would remove runner via API (ID: $runner_id)"; then
            gh api "repos/${GHR_REPO}/actions/runners/${runner_id}" -X DELETE 2>/dev/null || {
                warn "API deletion failed. Runner may need manual removal."
            }
        fi
    fi

    success "Runner removed from GitHub."
    info "Your runner directory at $GHR_DIR was kept. Delete manually if desired."
}

# ── Help ─────────────────────────────────────────────────────────────────────
show_help() {
    cat << 'EOF'
⚡ GitHub Self-Hosted Runner Setup (v${VERSION})

Usage:
  setup-runner.sh [OPTIONS]

Options:
  --uninstall     Remove an existing runner from GitHub and stop the service
  --replace       Replace an existing runner with the same name (default: true)
  --service       Install as a systemd/launchd service (opt-in, default: no)
  --dry-run, -n   Show what would happen without making changes
  --debug, -v     Enable verbose debug output
  --help          Show this help message

Environment variables (override defaults):
  GHR_REPO        owner/repo to register the runner for (prompted if unset)
  GHR_NAME        Runner name (default: hostname)
  GHR_LABELS      Comma-separated labels (auto-detected if unset)
  GHR_DIR         Install directory (default: ~/actions-runner/<repo>)
  GHR_WORK        Work subdirectory (default: _work)
  GHR_REPLACE     Replace existing runner (default: true)

Examples:
  # Interactive mode
  ./setup-runner.sh

  # Unattended mode
  GHR_REPO=owner/repo GHR_NAME=my-runner GHR_LABELS=self-hosted,linux \
    ./setup-runner.sh

  # With systemd service
  GHR_REPO=owner/repo ./setup-runner.sh --service

  # Uninstall
  ./setup-runner.sh --uninstall
EOF
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    trap 'echo; warn "Interrupted. Run --uninstall to clean up if needed."; exit 130' INT TERM
    cleanup() {
        local exit_code=$?
        if [[ $exit_code -ne 0 && $exit_code -ne 130 ]]; then
            warn "Script exited with code $exit_code."
            warn "If install was interrupted, run: $0 --uninstall"
        fi
    }
    trap cleanup EXIT

    local do_uninstall=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --uninstall) do_uninstall=true; shift ;;
            --replace)   export GHR_REPLACE=true; shift ;;
            --service)   export GHR_SERVICE=true; shift ;;
            --dry-run|-n) DRY_RUN=true; shift ;;
            --debug|-v)   DEBUG=true; shift ;;
            --help|-h)   show_help; exit 0 ;;
            *)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    export DRY_RUN DEBUG
    # Detect unattended mode (GHR_REPO set from env = no prompts)
    local unattended=false
    if [[ -n "${GHR_REPO:-}" ]]; then
        unattended=true
    fi
    export GHR_UNATTENDED="$unattended"

    # Set defaults (GHR_DIR set after select_repo since it depends on repo name)
    export GHR_WORK="${GHR_WORK:-_work}"
    export GHR_NAME="${GHR_NAME:-$(hostname | cut -d. -f1)}"
    export GHR_REPLACE="${GHR_REPLACE:-true}"
    # Validate runner name (prevents jq injection and invalid systemd unit names)
    if [[ ! "$GHR_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        error "Invalid runner name: '$GHR_NAME'. Only alphanumeric, hyphens, and underscores allowed."
        exit 1
    fi

    info "gh-self-hosted-runner v${VERSION}"
    check_prereqs

    if [[ "$do_uninstall" == "true" ]]; then
        select_repo
        # Default GHR_DIR: ~/actions-runner/<repo-name>
        export GHR_DIR="${GHR_DIR:-$HOME/actions-runner/$(echo "$GHR_REPO" | cut -d/ -f2)}"
        uninstall_runner
    else
        select_repo
        # Default GHR_DIR: ~/actions-runner/<repo-name>
        export GHR_DIR="${GHR_DIR:-$HOME/actions-runner/$(echo "$GHR_REPO" | cut -d/ -f2)}"
        detect_labels
        install_runner
        verify_runner
    fi
}

main "$@"
