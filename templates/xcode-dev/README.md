# xcode-dev — macOS + Xcode CLI tools + Homebrew

**Most steps are automated. One step requires you to click through Apple's Setup Assistant manually** — Apple doesn't expose a scriptable skip path for it. After that, every rebuild is hands-off.

## Step 1: Run the OS install (CLI)

Use `vm4a create` to drive Apple's `VZMacOSInstaller` end-to-end with your IPSW. This takes 10–20 minutes and produces a bootable bundle.

```bash
vm4a create xcode-dev-base --os macOS \
    --image ~/Downloads/macos-15.ipsw \
    --storage ~/.cache/vm4a-templates/storage \
    --cpu 4 --memory-gb 8 --disk-gb 80
```

## Step 2: Click through Setup Assistant (one-time, manual)

Open VM4A.app, pick the bundle from the sidebar, click Run, then in the framebuffer:

1. Pick region/keyboard
2. Skip Apple ID and analytics
3. **Create a user account** — note the username
4. Once at the desktop, **System Settings → General → Sharing → Remote Login: ON**

Stop the VM. From here on, everything is automated.

## Step 3: Provision + push (automated)

```bash
export VM4A_REGISTRY_USER=youruser
export VM4A_REGISTRY_PASSWORD=ghp_xxx     # PAT with write:packages
export XCODE_DEV_BASE_BUNDLE=~/.cache/vm4a-templates/storage/xcode-dev-base
export XCODE_DEV_SSH_USER=youruser        # the account from step 2
# Optional: export XCODE_DEV_SSH_KEY=~/.ssh/vm4a_ed25519

./build.sh
```

`build.sh` will:

1. Start the base bundle with `--save-on-stop` armed
2. Wait for SSH to respond (the user account from step 2 is what we connect as)
3. Upload `provision.sh` and run it (Xcode CLT + Homebrew + brew install of `git`, `ripgrep`, `jq`)
4. Stop the VM, which writes `clean.vzstate` to the bundle
5. Push to `ghcr.io/everettjf/vm4a-templates/xcode-dev:<date>` and `:latest`

Provisioning takes another 10–20 minutes the first time because Xcode Command Line Tools and Homebrew are large.

## Why does Setup Assistant need a human?

Apple's macOS guest first-boot has two stages that need cooperation from inside the VM:

1. **Setup Assistant** asks for region, Apple ID, user account, etc. There's no public API to skip it.
2. **Remote Login** is off by default. SSH can't be used until the user enables it.

Both could in theory be addressed by pre-baking auxiliary plists into `AuxiliaryStorage` (a la `osx-provisioner`/`tart`-style tools), but Apple hasn't documented this surface, and what's possible drifts across macOS versions. Until Apple ships an official answer-file path or an MDM-style remote enrolment SDK that vm4a can drive, this one-time manual step is unavoidable for a fresh IPSW.

If you have a working autounattend recipe for a current macOS, open an issue or PR — we'd love to ship a fully automated `build-from-ipsw.sh`.

## After it's published

Consumers don't pay any of these costs — they just pull:

```bash
vm4a spawn dev --os macOS \
    --from ghcr.io/everettjf/vm4a-templates/xcode-dev:latest \
    --storage /tmp/vm4a --wait-ssh
```

Pulling a pre-installed bundle skips Setup Assistant entirely (the user already exists, Remote Login is already on, the snapshot was saved post-setup).
