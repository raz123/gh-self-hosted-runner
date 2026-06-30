# ⚡ gh-self-hosted-runner

```bash
curl -sSL https://github.com/raz123/gh-self-hosted-runner/releases/latest/download/setup-runner.sh | bash
```

*Install a self-hosted GitHub Actions runner in one command. Interactive repo picker, auto-label detection, works on Linux & macOS.*

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

# Uninstall
./setup-runner.sh --uninstall

# See all options
./setup-runner.sh --help
```

## 🔧 Prerequisites

- [`gh` CLI](https://cli.github.com) installed and logged in (`gh auth login`)
- `curl`, `tar`, `jq` (pre-installed on most systems)
- Root or `sudo` access

## 🗑️ Uninstall

```bash
./setup-runner.sh --uninstall
# Removes runner from GitHub, stops service, cleans config.
# Your runner directory is kept; delete manually if desired.
```

## 📄 License

MIT © [raz123](https://github.com/raz123)
