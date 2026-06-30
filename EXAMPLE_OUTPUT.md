# Example Output

What you'll see when you run the setup script:

```
 ── Prerequisites ────────────────────────────────────────────────────

    ✔  gh CLI authenticated
    ✔  curl, tar, jq found
    ✔  Detected OS: Linux → platform=linux
    ✔  Detected arch: x86_64 → arch=x64

 ── Repository Selection ─────────────────────────────────────────────

    Fetching repositories with admin access...
    Checking workflow counts...

    Select a repository:
    ✔  Selected: raz123/android_kernel_redalpha_pocof3

 ── Label Detection ──────────────────────────────────────────────────

    Detecting runner labels from workflows...
    Non-interactive: using auto-detected labels
    ✔  Labels: self-hosted,linux

 ── Install & Register ───────────────────────────────────────────────

    Installing runner to ~/actions-runner/android_kernel_redalpha_pocof3
    Removing existing runner configuration...

    # Runner removal
    √  Runner removed successfully
    √  Removed .credentials
    √  Removed .runner

    Generating registration token...
    Fetching latest runner release...
    Using cached runner archive.
    Extracting runner...
    Configuring runner...

    # Runner Registration
    √  Runner successfully added

    # Runner settings
    √  Settings Saved.

    ✔  Runner installed!

    → Launch the runner now? [Y/n]: n

    To run the runner later:
      cd ~/actions-runner/android_kernel_redalpha_pocof3 && ./run.sh

 ── Verify ───────────────────────────────────────────────────────────

    Verifying runner status...

    ✔  Runner 'dell' is ONLINE
      Repo:   raz123/android_kernel_redalpha_pocof3
      Labels: self-hosted, linux
      Manage: https://github.com/raz123/android_kernel_redalpha_pocof3/settings/actions/runners
```
