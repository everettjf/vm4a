# xcode-dev — macOS + Xcode CLI tools + Homebrew

**Build is partly automated.** Apple's `VZMacOSInstaller` handles the OS install but the resulting VM still boots into Setup Assistant, which has no documented scripted-skip path. So you create the base bundle *once* via the GUI (download IPSW + first-boot user creation), then `build.sh` takes over — uploads `provision.sh`, installs Xcode CLT + Homebrew + brew tools, snapshots, and pushes.

## One-time base setup (manual)

1. Open VM4A.app → File → New macOS VM → pick a Sequoia (or newer) IPSW.
2. Wait for first boot. Create the user account, **enable Remote Login** (System Settings → General → Sharing).
3. Note the SSH username you just created and the bundle's path on disk.

## Provisioning + push (automated)

```bash
export VM4A_REGISTRY_USER=youruser
export VM4A_REGISTRY_PASSWORD=ghp_xxx     # PAT with write:packages
export XCODE_DEV_BASE_BUNDLE=~/Library/Containers/.../macos-base
export XCODE_DEV_SSH_USER=youruser
# Optional: export XCODE_DEV_SSH_KEY=~/.ssh/vm4a_ed25519

./build.sh
```

`build.sh` will:

1. Start the base bundle with `--save-on-stop` armed
2. Wait for SSH to respond
3. Upload `provision.sh` and run it (Xcode CLT + Homebrew + brew install of `git`, `ripgrep`, `jq`)
4. Stop the VM, which writes `clean.vzstate` to the bundle
5. Push to `ghcr.io/everettjf/vm4a-templates/xcode-dev:<date>` and `:latest`

The provisioning step takes 10–20 minutes the first time because Xcode Command Line Tools and Homebrew are large.

## Why isn't the base install scripted?

Apple's macOS guest first-boot has two stages that need cooperation from inside the VM:

1. **Setup Assistant** asks for region, Apple ID, user account, etc. There's no public API to skip it from outside the VM.
2. **Remote Login** is off by default. SSH can't be used until the user enables it interactively.

Both could in theory be addressed by pre-baking auxiliary plists into `auxiliaryStorage` (a la `osx-provisioner`-style tools), but Apple has not documented this surface, and what's possible has changed across macOS versions. Until Apple ships an official answer-file path or an MDM-style remote enrolment SDK that vm4a can drive, this manual base step is the best we can do.

If you have a working autounattend recipe for a current macOS, open an issue or PR — we'd love to ship a fully automated `build-from-ipsw.sh`.
