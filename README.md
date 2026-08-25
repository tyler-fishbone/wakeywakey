# WakeyWakey 🥚🥓☕️

Menu-bar **lid-closed keep-awake** for macOS.

Keeps the Mac awake (SSH, builds, long jobs) with the lid shut, turns displays off, and respects power + thermal limits so a sealed backpack is less likely to cook the machine.

Built on **SwiftBar** + a small **root LaunchDaemon** that toggles `pmset disablesleep` (not `caffeinate`).

## Install

Pick one. Admin password is required once (daemon install).

### Option A — one-liner (recommended)

Avoids the Gatekeeper “untrusted developer” double-click block:

```bash
curl -fsSL https://raw.githubusercontent.com/zjdonhauser/wakeywakey/main/install.sh | bash
```

### Option B — clone, then run

```bash
git clone https://github.com/zjdonhauser/wakeywakey.git
bash wakeywakey/install.sh
```

### Option C — download the `.command` file

1. Download [`WakeyWakey-install.command`](https://github.com/zjdonhauser/wakeywakey/raw/main/WakeyWakey-install.command)
2. **Right-click → Open → Open** the first time (Gatekeeper)
3. After that, double-click works

### Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/zjdonhauser/wakeywakey/main/install.sh | bash -s -- --uninstall
```

Or: `bash install.sh --uninstall`

## What you get

| Piece | Role |
|---|---|
| **SwiftBar** | Menu-bar UI (installed via Homebrew or GitHub release if missing) |
| **WakeyWakey plugin** | Mode picker + live thermal readout |
| **`local.wakeywakey` daemon** | Every 5s: enforce sleep policy, blank displays when lid closed |

### Keep-awake modes

- 💤 Off (normal sleep)
- 🥚 On — while plugged in only
- 🥓 On — while AC or battery ≥ 50%
- ☕️ On — always

### Thermal pause

If Apple thermal pressure reaches your threshold, keep-awake **pauses** (saved mode is unchanged; it resumes when cooler).

- 🌡️ Fair
- ♨️ Serious (**default** for new installs)
- 🔥 Critical — for sustained high heat

Change the threshold in the menu. Your choice is stored in `~/.config/wakeywakey/max-thermal`.

## Gatekeeper / “untrusted” installer

Apple blocks unsigned downloads opened via Finder until you approve them.

**You do not need a paid Apple Developer account** for personal use. Without Apple’s notarization ($99/year Developer Program):

| Method | Gatekeeper |
|---|---|
| `curl \| bash` or `git clone` + `bash` | No Finder quarantine prompt |
| Download `.command` + **Right-click → Open** | One-time approve |
| Double-click a fresh download | Blocked until you use Right-click → Open |

Full notarization (no warnings for strangers double-clicking a downloaded app) requires the paid Apple Developer Program. This project stays a shell installer on purpose.

## Requirements

- macOS (Apple Silicon or Intel)
- Admin rights once
- Optional: Homebrew (used for SwiftBar if present; otherwise downloads SwiftBar from GitHub)
- Optional: Xcode Command Line Tools (`swiftc`) for layered menu-bar icons; falls back to plain emoji if missing

## Safe / idempotent

Re-running the installer is safe. It keeps your current mode and thermal threshold.

## Updates

The menu checks [version.txt](version.txt) on GitHub about every **3 days** (quiet, 2s timeout; failures are ignored).

- If a newer version exists → **⬆ Update WakeyWakey** (re-runs `install.sh` from this repo; may ask for your Mac password)
- Otherwise → **Check for update** (checks now)

Override the repo (e.g. a fork):

```bash
echo 'youruser/wakeywakey' > ~/.config/wakeywakey/repo
echo 'main' > ~/.config/wakeywakey/branch
```

## License

MIT — see [LICENSE](LICENSE).
