# xcode-dev — macOS + Xcode CLI tools

**Manual build.** Unlike the Linux templates, the macOS guest install requires interactive setup that the CLI skeleton can't drive end-to-end. Use the GUI app to produce the base bundle, then run `provision.sh` over SSH to bake the development tools.

## Steps

1. **GUI install.** Open VM4A.app → File → New macOS VM → Sequoia (or your preferred version). Wait for first boot. Create a user, enable Remote Login (System Settings → General → Sharing), note the IP from `vm4a ip`.

2. **Verify SSH.**
   ```bash
   vm4a exec /path/to/macos-vm --user youruser -- whoami
   ```

3. **Provision.**
   ```bash
   vm4a cp /path/to/macos-vm --user youruser ./provision.sh :/tmp/provision.sh
   vm4a exec /path/to/macos-vm --user youruser --timeout 1800 -- \
       bash -lc 'sudo bash /tmp/provision.sh'
   ```

4. **Snapshot + push.**
   ```bash
   # Re-run with --save-on-stop armed:
   vm4a stop /path/to/macos-vm
   vm4a run /path/to/macos-vm --save-on-stop /path/to/macos-vm/clean.vzstate &
   sleep 60
   vm4a stop /path/to/macos-vm
   vm4a push /path/to/macos-vm ghcr.io/everettjf/vm4a-templates/xcode-dev:latest
   ```

## What `provision.sh` installs

- Xcode Command Line Tools (`xcode-select --install` flow, scripted)
- Homebrew (default `/opt/homebrew` install)
- `git`, `ripgrep`, `jq`

For full Xcode (the IDE), download the `.xip` interactively the first time, then re-snapshot.
