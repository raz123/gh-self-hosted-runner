# ⚡ gh-self-hosted-runner

*Install a self-hosted GitHub Actions runner in one command. Interactive repo picker, auto-label detection, works on Linux & macOS.*

## Quick Install

```bash
curl -fsSL https://github.com/raz123/gh-self-hosted-runner/releases/latest/download/setup-runner.sh | bash
```

Preview what it does first:

```bash
curl -fsSL https://github.com/raz123/gh-self-hosted-runner/releases/latest/download/setup-runner.sh | bash -s -- --dry-run
```

If `sudo` prompts fail (piped stdin), use a writable directory:

```bash
curl -fsSL https://github.com/raz123/gh-self-hosted-runner/releases/latest/download/setup-runner.sh | bash -s -- GHR_DIR=~/actions-runner
```

## ✨ Features

| 🔍 Interactive | 🏷️ Auto-labels | 🖥️ Cross-platform | 🧹 Clean uninstall |
|:--|:--|:--|:--|
| Pick your repo from a live GitHub menu | Detects runner labels from your workflows | Linux (systemd) + macOS (launchd) | `--uninstall` removes everything |

## 📦 Usage

```bash
# Interactive (guided)
./setup-runner.sh

# Unattended (CI/scripts)
GHR_REPO=owner/repo \
GHR_NAME=my-runner \
GHR_LABELS=self-hosted,linux \
./setup-runner.sh

# Dry run (preview without changes)
./setup-runner.sh --dry-run

# Debug output
./setup-runner.sh --debug

# Uninstall
./setup-runner.sh --uninstall

# See all options
./setup-runner.sh --help
```

## 🔧 Prerequisites

- [`gh` CLI](https://cli.github.com) installed and logged in (`gh auth login`)
- `curl`, `tar`, `jq` (pre-installed on most systems)
- Root or `sudo` access (or set `GHR_DIR` to a writable path)

## 🗑️ Uninstall

```bash
./setup-runner.sh --uninstall
# Removes runner from GitHub, stops service, cleans config.
# Your runner directory is kept; delete manually if desired.
```

## 📄 License

MIT © [raz123](https://github.com/raz123)
