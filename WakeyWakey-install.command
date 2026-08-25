#!/bin/bash
#
#  WakeyWakey — menu-bar lid-closed keep-awake for macOS  🥚🥓☕️
#
#  INSTALL (pick one):
#    • Double-click this file
#    • Or in Terminal:  bash "WakeyWakey-install.command"
#  First open after download/AirDrop: Right-click the file → Open → Open
#  (Gatekeeper blocks unsigned downloads until you approve once.)
#
#  Uninstall:  bash "WakeyWakey-install.command" --uninstall
#
#  Idempotent — safe to re-run. Installs SwiftBar if missing, turns on
#  launch-at-login, and installs/refreshes the keep-awake daemon.
#
set -euo pipefail

# Released version + GitHub source (plugin checks this for updates)
WAKEY_VERSION="1.2.0"
WAKEY_REPO="zjdonhauser/wakeywakey"
WAKEY_BRANCH="main"
WAKEY_RAW_BASE="https://raw.githubusercontent.com/${WAKEY_REPO}/${WAKEY_BRANCH}"

# Keep the Terminal window readable when launched by double-click.
# Skip with: WAKEYWAKEY_NO_PAUSE=1 bash "WakeyWakey-install.command"
PAUSE_AT_END=0
if [ -t 0 ] && [ -z "${CI:-}" ] && [ -z "${WAKEYWAKEY_NO_PAUSE:-}" ]; then
  PAUSE_AT_END=1
fi

pause() {
  [ "$PAUSE_AT_END" = "1" ] || return 0
  echo ""
  read -r -p "Press Return to close this window…" _
}

die() {
  echo "✗ $*" >&2
  pause
  exit 1
}

trap 'ec=$?; if [ $ec -ne 0 ]; then echo ""; echo "✗ Install failed (exit $ec)."; pause; fi' EXIT

# --- self-heal Gatekeeper quarantine on this script (helps AirDrop / Downloads) ---
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
# Resolve to absolute when possible
if command -v realpath >/dev/null 2>&1; then
  SCRIPT_PATH="$(realpath "$SCRIPT_PATH" 2>/dev/null || echo "$SCRIPT_PATH")"
elif [[ "$SCRIPT_PATH" != /* ]]; then
  SCRIPT_PATH="$PWD/$SCRIPT_PATH"
fi
xattr -d com.apple.quarantine "$SCRIPT_PATH" 2>/dev/null || true

if [ "$(id -u)" = "0" ]; then
  die "Run this as your normal user (not with sudo) — it asks for your password when needed."
fi

USER_HOME="$HOME"
STATE_DIR="$USER_HOME/.config/wakeywakey"
RECONCILE_BIN="/usr/local/bin/wakeywakey-reconcile"
PLIST="/Library/LaunchDaemons/local.wakeywakey.plist"
LOG="/var/log/wakeywakey.log"
SWIFTBAR_APP="/Applications/SwiftBar.app"
SWIFTBAR_REPO="swiftbar/SwiftBar"
ASKPASS_HELPER=""

# sudo without a TTY (IDE agents, some double-click edge cases) needs a GUI password prompt.
setup_sudo() {
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  if [ -t 0 ] && [ -z "${SUDO_ASKPASS:-}" ]; then
    return 0  # normal Terminal — sudo can prompt here
  fi
  ASKPASS_HELPER="$(mktemp /tmp/wakeywakey-askpass.XXXXXX)"
  cat > "$ASKPASS_HELPER" <<'ASK'
#!/bin/bash
osascript <<'APPLESCRIPT'
try
  set d to display dialog "WakeyWakey needs your Mac password to install the keep-awake daemon." & return & return & "Password:" default answer "" with title "WakeyWakey" with hidden answer buttons {"Cancel", "OK"} default button "OK" cancel button "Cancel"
  return text returned of d
on error
  return ""
end try
APPLESCRIPT
ASK
  chmod 700 "$ASKPASS_HELPER"
  export SUDO_ASKPASS="$ASKPASS_HELPER"
}
run_sudo() {
  if [ -n "${SUDO_ASKPASS:-}" ]; then
    command sudo -A "$@"
  else
    command sudo "$@"
  fi
}
cleanup_askpass() {
  [ -n "$ASKPASS_HELPER" ] && rm -f "$ASKPASS_HELPER" && ASKPASS_HELPER=""
  true
}

arch_name() {
  case "$(uname -m)" in
    arm64|aarch64) echo "arm64" ;;
    x86_64) echo "x86_64" ;;
    *) echo "$(uname -m)" ;;
  esac
}

plugin_dir() {
  local d
  d="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
  [ -z "$d" ] && d="$USER_HOME/.config/swiftbar-plugins"
  echo "$d"
}

uninstall() {
  echo "Removing WakeyWakey…"
  setup_sudo
  run_sudo launchctl bootout system/local.wakeywakey 2>/dev/null || true
  run_sudo rm -f "$PLIST" "$RECONCILE_BIN" "$LOG"
  run_sudo pmset -a disablesleep 0 2>/dev/null || true
  cleanup_askpass
  rm -f "$(plugin_dir)/wakeywakey.5s.sh"
  rm -rf "$STATE_DIR"
  echo "✓ WakeyWakey removed; normal sleep restored."
  echo "  (SwiftBar itself was left installed — remove it from /Applications if you want.)"
  pause
  trap - EXIT
  exit 0
}

if [ "${1:-}" = "--uninstall" ]; then uninstall; fi
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<EOF
WakeyWakey installer

  Double-click this file, or:
    bash "$SCRIPT_PATH"
    bash "$SCRIPT_PATH" --uninstall

Installs (idempotent):
  • SwiftBar menu-bar host (download from GitHub if missing; brew if present)
  • SwiftBar launch-at-login
  • WakeyWakey menu plugin + root keep-awake daemon (every 5s)
  • Thermal pause at Serious by default (menu-configurable); menu shows live level
EOF
  trap - EXIT
  exit 0
fi

echo "══════════════════════════════════════════════"
echo "  WakeyWakey installer  🥚🥓☕️"
echo "  User: $(id -un)   Arch: $(arch_name)"
echo "══════════════════════════════════════════════"
echo ""

# 1) config dir — preserve existing mode on re-run
mkdir -p "$STATE_DIR"
if [ ! -f "$STATE_DIR/desired" ]; then
  printf 'off' > "$STATE_DIR/desired"
  echo "• Mode: off (pick one in the menu bar after install)"
else
  echo "• Mode: $(tr -d '[:space:]' < "$STATE_DIR/desired") (kept from previous install)"
fi
# Thermal pause threshold: 0 Nominal · 1 Fair · 2 Serious · 3 Critical · off = never
# Default Serious (2) — safer for new installs; users can raise to Critical in the menu.
if [ ! -f "$STATE_DIR/max-thermal" ]; then
  printf '2' > "$STATE_DIR/max-thermal"
  echo "• Thermal pause: Serious (level ≥ 2); change in the menu bar"
else
  echo "• Thermal pause: $(tr -d '[:space:]' < "$STATE_DIR/max-thermal") (kept; change in the menu bar)"
fi
printf '%s' "$WAKEY_VERSION" > "$STATE_DIR/version"
printf '%s' "$WAKEY_REPO" > "$STATE_DIR/repo"
printf '%s' "$WAKEY_BRANCH" > "$STATE_DIR/branch"
echo "• Version: $WAKEY_VERSION (updates from github.com/$WAKEY_REPO)"

# 1b) layered menu-bar icons (wake + temp badge) — SwiftBar can't stack plain emoji
ICON_DIR="$STATE_DIR/icons"
LAYER_BIN="$STATE_DIR/layer-icon"
LAYER_SRC="$STATE_DIR/layer-icon.swift"
mkdir -p "$ICON_DIR"
cat > "$LAYER_SRC" <<'SWIFT'
import AppKit
import Foundation

guard CommandLine.arguments.count >= 4 else {
  fputs("usage: layer-icon <wakeEmoji> <thermEmoji> <out.png>\n", stderr)
  exit(2)
}
let wake = CommandLine.arguments[1]
let therm = CommandLine.arguments[2]
let outPath = CommandLine.arguments[3]

let point: CGFloat = 18
let scale: CGFloat = 2
let px = Int(point * scale)

guard let rep = NSBitmapImageRep(
  bitmapDataPlanes: nil,
  pixelsWide: px,
  pixelsHigh: px,
  bitsPerSample: 8,
  samplesPerPixel: 4,
  hasAlpha: true,
  isPlanar: false,
  colorSpaceName: .deviceRGB,
  bytesPerRow: 0,
  bitsPerPixel: 0
) else {
  fputs("bitmap failed\n", stderr)
  exit(1)
}
rep.size = NSSize(width: point, height: point)

NSGraphicsContext.saveGraphicsState()
guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
  fputs("context failed\n", stderr)
  exit(1)
}
NSGraphicsContext.current = ctx
ctx.imageInterpolation = .high

NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: point, height: point).fill()

let wakeAttrs: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 14)
]
let wakeSize = (wake as NSString).size(withAttributes: wakeAttrs)
(wake as NSString).draw(
  at: NSPoint(x: (point - wakeSize.width) / 2 - 0.5, y: (point - wakeSize.height) / 2 + 0.5),
  withAttributes: wakeAttrs
)

let thermAttrs: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 10)
]
let thermSize = (therm as NSString).size(withAttributes: thermAttrs)
(therm as NSString).draw(
  at: NSPoint(x: point - thermSize.width + 0.5, y: -1.5),
  withAttributes: thermAttrs
)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
  fputs("png failed\n", stderr)
  exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
SWIFT

build_layered_icons() {
  if ! command -v swiftc >/dev/null 2>&1; then
    echo "• Layered icons skipped (no swiftc / Xcode CLT) — menu falls back to side-by-side emoji"
    return 0
  fi
  echo "• Building layered menu-bar icons…"
  if ! swiftc -O "$LAYER_SRC" -o "$LAYER_BIN" 2>/tmp/wakeywakey-swiftc.err; then
    echo "  ⚠ swiftc failed — menu falls back to side-by-side emoji"
    head -5 /tmp/wakeywakey-swiftc.err 2>/dev/null || true
    return 0
  fi
  # wake × Fair/Serious/Critical only (no Nominal badge)
  rm -f "$ICON_DIR"/*-0.png 2>/dev/null || true
  local w_emoji t_emoji key t
  for pair in on:☕️ ac:🥚 batt:🥓; do
    key="${pair%%:*}"
    w_emoji="${pair#*:}"
    for t in 1 2 3; do
      case "$t" in
        1) t_emoji="🌡️" ;;
        2) t_emoji="♨️" ;;
        3) t_emoji="🔥" ;;
      esac
      "$LAYER_BIN" "$w_emoji" "$t_emoji" "$ICON_DIR/${key}-${t}.png" || true
    done
  done
  local n
  n="$(ls -1 "$ICON_DIR"/*.png 2>/dev/null | wc -l | tr -d ' ')"
  echo "• Layered icons ready ($n PNGs in $ICON_DIR)"
}
build_layered_icons

# 2) reconcile script (runs as ROOT via launchd — bake in this user's state path)
TMP_RECONCILE="$STATE_DIR/wakeywakey-reconcile"
cat > "$TMP_RECONCILE" <<EOF
#!/bin/bash
# wakeywakey-reconcile — run as root by the local.wakeywakey LaunchDaemon every 5s.
# Enforces \`pmset disablesleep\` from the user's chosen mode; blanks displays on lid-close.
# Pauses keep-awake when Apple thermal pressure reaches max-thermal (does not change desired mode).
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:\$PATH"
STATE_DIR="$STATE_DIR"
STATE_FILE="$STATE_DIR/desired"
THERM_FILE="$STATE_DIR/max-thermal"
EOF
cat >> "$TMP_RECONCILE" <<'EOF'
mode="off"
[ -r "$STATE_FILE" ] && mode="$(tr -d '[:space:]' < "$STATE_FILE")"
[ -z "$mode" ] && mode="off"

max_therm=2
[ -r "$THERM_FILE" ] && max_therm="$(tr -d '[:space:]' < "$THERM_FILE")"
[ -z "$max_therm" ] && max_therm=2

# 0 Nominal · 1 Fair · 2 Serious · 3 Critical (com.apple.system.thermalpressurelevel)
therm=0
therm_raw="$(notifyutil -g com.apple.system.thermalpressurelevel 2>/dev/null || true)"
therm="$(printf '%s\n' "$therm_raw" | awk '{print $NF}')"
case "$therm" in
  ''|*[!0-9]*) therm=0 ;;
esac

batt_raw="$(pmset -g batt 2>/dev/null)"
on_ac=0; case "$batt_raw" in *"AC Power"*) on_ac=1 ;; esac
pct="$(printf '%s\n' "$batt_raw" | grep -Eo '[0-9]+%' | head -1 | tr -d '%')"
[ -z "$pct" ] && pct=100

want=0
case "$mode" in
  on) want=1 ;;
  ac) [ "$on_ac" -eq 1 ] && want=1 ;;
  batt:*)
    thr="${mode#batt:}"; [ -z "$thr" ] && thr=50
    [ "$on_ac" -eq 1 ] && want=1
    if [ "$pct" -ge "$thr" ] 2>/dev/null; then want=1; fi
    ;;
  *) want=0 ;;
esac

# Hot Mac: release sleep even if mode says keep awake. Default threshold is Serious (2).
# max_therm=off disables this.
thermal_pause=0
if [ "$want" = "1" ] && [ "$max_therm" != "off" ] && [ "$therm" -ge "$max_therm" ] 2>/dev/null; then
  want=0
  thermal_pause=1
fi

cur="$(pmset -g 2>/dev/null | awk '/SleepDisabled/{print $2; exit}')"
[ -z "$cur" ] && cur=0

if [ "$cur" != "$want" ]; then
  pmset -a disablesleep "$want" \
    && logger -t wakeywakey "mode=$mode ac=$on_ac pct=${pct}% therm=$therm max=$max_therm pause=$thermal_pause -> disablesleep $want (was $cur)"
fi

if [ "$want" = "1" ]; then
  clamshell="$(ioreg -r -k AppleClamshellState 2>/dev/null | awk -F'= ' '/AppleClamshellState/{print $2; exit}' | tr -d ' ')"
  if [ "$clamshell" = "Yes" ]; then
    pmset displaysleepnow 2>/dev/null
  fi
fi
EOF
chmod +x "$TMP_RECONCILE"

# 3) LaunchDaemon plist
TMP_PLIST="$STATE_DIR/local.wakeywakey.plist"
cat > "$TMP_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>local.wakeywakey</string>
    <key>ProgramArguments</key><array><string>$RECONCILE_BIN</string></array>
    <key>StartInterval</key><integer>5</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

# 4) SwiftBar — existing → brew → GitHub zip (universal binary)
install_swiftbar_from_github() {
  echo "• Downloading SwiftBar from GitHub releases…"
  command -v curl >/dev/null 2>&1 || die "curl is required to download SwiftBar"
  command -v ditto >/dev/null 2>&1 || die "ditto is required to unpack SwiftBar"
  command -v python3 >/dev/null 2>&1 || die "python3 is required to pick the SwiftBar release asset"

  local api_json tmp zip_url zip_path extract_dir app_src
  tmp="$(mktemp -d /tmp/wakeywakey-swiftbar.XXXXXX)"
  cleanup_tmp() { rm -rf "$tmp"; }
  # Ensure cleanup on failure paths inside this function
  # (die → EXIT; success → explicit cleanup below)

  api_json="$tmp/release.json"
  if ! curl -fsSL "https://api.github.com/repos/${SWIFTBAR_REPO}/releases/latest" -o "$api_json"; then
    cleanup_tmp
    die "Could not reach GitHub for the latest SwiftBar release"
  fi

  if ! zip_url="$(python3 - "$api_json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
assets = data.get("assets") or []
candidates = [a for a in assets if a.get("name", "").endswith(".zip") and "SwiftBar" in a.get("name", "")]
if not candidates:
    candidates = [a for a in assets if a.get("name", "").endswith(".zip")]
if not candidates:
    sys.exit(2)
print(candidates[0]["browser_download_url"])
PY
)"; then
    cleanup_tmp
    die "No SwiftBar .zip asset found on the latest GitHub release"
  fi

  zip_path="$tmp/SwiftBar.zip"
  if ! curl -fL --progress-bar "$zip_url" -o "$zip_path"; then
    cleanup_tmp
    die "SwiftBar download failed"
  fi

  extract_dir="$tmp/extract"
  mkdir -p "$extract_dir"
  if ! ditto -xk "$zip_path" "$extract_dir"; then
    cleanup_tmp
    die "Could not unpack SwiftBar.zip"
  fi

  app_src="$(find "$extract_dir" -maxdepth 3 -name 'SwiftBar.app' -type d | head -1)"
  if [ -z "$app_src" ]; then
    cleanup_tmp
    die "SwiftBar.app missing from the downloaded archive"
  fi

  xattr -cr "$app_src" 2>/dev/null || true

  if [ -d "$SWIFTBAR_APP" ]; then
    echo "• Updating SwiftBar in /Applications…"
    if ! ditto "$app_src" "$SWIFTBAR_APP" 2>/dev/null; then
      run_sudo rm -rf "$SWIFTBAR_APP"
      run_sudo ditto "$app_src" "$SWIFTBAR_APP"
    fi
  else
    if ! ditto "$app_src" "$SWIFTBAR_APP" 2>/dev/null; then
      echo "  (need admin password to install into /Applications)"
      run_sudo ditto "$app_src" "$SWIFTBAR_APP"
    fi
  fi
  xattr -cr "$SWIFTBAR_APP" 2>/dev/null || true
  cleanup_tmp
  echo "✓ SwiftBar installed at $SWIFTBAR_APP"
}

ensure_swiftbar() {
  if [ -d "$SWIFTBAR_APP" ]; then
    echo "• SwiftBar already installed"
    return 0
  fi
  if command -v brew >/dev/null 2>&1; then
    echo "• Installing SwiftBar via Homebrew…"
    if brew install --cask swiftbar; then
      [ -d "$SWIFTBAR_APP" ] && return 0
    fi
    echo "  ⚠ brew cask install did not leave SwiftBar in /Applications — trying GitHub…"
  fi
  install_swiftbar_from_github
  [ -d "$SWIFTBAR_APP" ] || die "SwiftBar is still missing after install"
}

setup_sudo
ensure_swiftbar

# 5) SwiftBar plugin dir + launch-at-login
PLUGIN_DIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
if [ -z "$PLUGIN_DIR" ]; then
  PLUGIN_DIR="$USER_HOME/.config/swiftbar-plugins"
fi
mkdir -p "$PLUGIN_DIR"
defaults write com.ameba.SwiftBar PluginDirectory -string "$PLUGIN_DIR"
defaults write com.ameba.SwiftBar LaunchAtLogin -bool true
defaults write com.ameba.SwiftBar SwiftBarLaunchAtLogin -bool true
defaults write com.ameba.SwiftBar MakePluginExecutable -bool true
echo "• SwiftBar plugin dir: $PLUGIN_DIR"
echo "• SwiftBar launch-at-login: on"

PLUGIN="$PLUGIN_DIR/wakeywakey.5s.sh"
cat > "$PLUGIN" <<EOF
#!/bin/bash
# WakeyWakey — SwiftBar menu UI.
# <bitbar.title>WakeyWakey</bitbar.title>
# <bitbar.desc>Lid-closed keep-awake with power conditions. 🥚🥓☕️</bitbar.desc>
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:\$PATH"
STATE_DIR="$STATE_DIR"
WAKEY_RAW_BASE="$WAKEY_RAW_BASE"
EOF
cat >> "$PLUGIN" <<'EOF'
STATE_FILE="$STATE_DIR/desired"
THERM_FILE="$STATE_DIR/max-thermal"
VERSION_FILE="$STATE_DIR/version"
SELF="$0"

# Allow override: echo 'otheruser/wakeywakey' > ~/.config/wakeywakey/repo
if [ -r "$STATE_DIR/repo" ]; then
  _repo="$(tr -d '[:space:]' < "$STATE_DIR/repo")"
  _branch="main"
  [ -r "$STATE_DIR/branch" ] && _branch="$(tr -d '[:space:]' < "$STATE_DIR/branch")"
  [ -n "$_repo" ] && WAKEY_RAW_BASE="https://raw.githubusercontent.com/${_repo}/${_branch:-main}"
fi

if [ "${1:-}" = "set" ]; then
  mkdir -p "$STATE_DIR"; printf '%s' "${2:-off}" > "$STATE_FILE"; exit 0
fi
if [ "${1:-}" = "set-therm" ]; then
  mkdir -p "$STATE_DIR"; printf '%s' "${2:-2}" > "$THERM_FILE"; exit 0
fi
# Quiet remote version check every 3 days (cached; never blocks menu on failure)
maybe_check_update() {
  local force="${1:-}" now last interval=259200 remote local_v newest
  now="$(date +%s)"
  last=0
  [ -r "$STATE_DIR/update-checked-at" ] && last="$(tr -d '[:space:]' < "$STATE_DIR/update-checked-at")"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$force" != "force" ] && [ $((now - last)) -lt "$interval" ]; then
    return 0
  fi
  remote="$(curl -fsSL --max-time 2 "$WAKEY_RAW_BASE/VERSION" 2>/dev/null | tr -d '[:space:]')" || {
    printf '%s' "$now" > "$STATE_DIR/update-checked-at"
    return 0
  }
  printf '%s' "$now" > "$STATE_DIR/update-checked-at"
  [ -z "$remote" ] && return 0
  local_v=""
  [ -r "$VERSION_FILE" ] && local_v="$(tr -d '[:space:]' < "$VERSION_FILE")"
  if [ -z "$local_v" ]; then
    printf '%s' "$remote" > "$STATE_DIR/update-available"
    return 0
  fi
  if [ "$remote" = "$local_v" ]; then
    rm -f "$STATE_DIR/update-available"
    return 0
  fi
  newest="$(printf '%s\n%s\n' "$local_v" "$remote" | sort -V | tail -1)"
  if [ "$newest" = "$remote" ]; then
    printf '%s' "$remote" > "$STATE_DIR/update-available"
  else
    rm -f "$STATE_DIR/update-available"
  fi
}

if [ "${1:-}" = "update" ]; then
  echo "Updating WakeyWakey from $WAKEY_RAW_BASE …"
  curl -fsSL "$WAKEY_RAW_BASE/install.sh" | WAKEYWAKEY_NO_PAUSE=1 bash
  exit 0
fi
if [ "${1:-}" = "check-update" ]; then
  maybe_check_update force
  exit 0
fi

maybe_check_update

mode="off"; [ -r "$STATE_FILE" ] && mode="$(tr -d '[:space:]' < "$STATE_FILE")"; [ -z "$mode" ] && mode="off"
cur="$(pmset -g 2>/dev/null | awk '/SleepDisabled/{print $2; exit}')"; [ -z "$cur" ] && cur=0
batt_raw="$(pmset -g batt 2>/dev/null)"
on_ac=0; case "$batt_raw" in *"AC Power"*) on_ac=1 ;; esac
pct="$(printf '%s\n' "$batt_raw" | grep -Eo '[0-9]+%' | head -1)"

max_therm=2
[ -r "$THERM_FILE" ] && max_therm="$(tr -d '[:space:]' < "$THERM_FILE")"
[ -z "$max_therm" ] && max_therm=2

therm=0
therm_raw="$(notifyutil -g com.apple.system.thermalpressurelevel 2>/dev/null || true)"
therm="$(printf '%s\n' "$therm_raw" | awk '{print $NF}')"
case "$therm" in
  ''|*[!0-9]*) therm=0 ;;
esac
case "$therm" in
  0) therm_name="Nominal" ;;
  1) therm_name="Fair" ;;
  2) therm_name="Serious" ;;
  3) therm_name="Critical" ;;
  *) therm_name="Unknown ($therm)" ;;
esac

# Would mode want awake right now (ignoring thermal)?
would=0
case "$mode" in
  on) would=1 ;;
  ac) [ "$on_ac" -eq 1 ] && would=1 ;;
  batt:*)
    thr="${mode#batt:}"; [ -z "$thr" ] && thr=50
    [ "$on_ac" -eq 1 ] && would=1
    pct_n="$(printf '%s' "${pct:-0}" | tr -d '%')"
    if [ "${pct_n:-0}" -ge "$thr" ] 2>/dev/null; then would=1; fi
    ;;
esac
thermal_pause=0
if [ "$would" = "1" ] && [ "$max_therm" != "off" ] && [ "$therm" -ge "$max_therm" ] 2>/dev/null; then
  thermal_pause=1
fi

# Heat badge: Fair / Serious / Critical (none at Nominal)
therm_icon() {
  case "$1" in
    1) printf '🌡️' ;;
    2) printf '♨️' ;;
    3) printf '🔥' ;;
    *) printf '' ;;
  esac
}
ICON_DIR="$STATE_DIR/icons"
if [ "$thermal_pause" = "1" ]; then
  # Heat disabled keep-awake — heat icon only
  echo "$(therm_icon "$therm")"
elif [ "$would" = "1" ] || [ "$cur" = "1" ]; then
  case "$mode" in
    on)     wake_key="on";   base="☕️" ;;
    ac)     wake_key="ac";   base="🥚" ;;
    batt:*) wake_key="batt"; base="🥓" ;;
    *)      wake_key="on";   base="☕️" ;;
  esac
  if [ "$therm" -ge 1 ] 2>/dev/null; then
    layered="$ICON_DIR/${wake_key}-${therm}.png"
    if [ -f "$layered" ]; then
      echo "| image=$(base64 -i "$layered" | tr -d '\n')"
    else
      echo "${base}$(therm_icon "$therm")"
    fi
  else
    echo "$base"
  fi
else
  echo "💤"
fi
echo "---"
echo "WakeyWakey 🥚🥓☕️ | size=14 color=#e0902a"
echo "---"
if [ "$thermal_pause" = "1" ]; then
  echo "Status: PAUSED — Mac is hot | color=#ff3b30"
elif [ "$cur" = "1" ]; then
  echo "Status: AWAKE — lid can be closed | color=#e0902a"
else
  echo "Status: normal sleep | color=#8e8e93"
fi
# Info-only rows (no bash=) — gray means “not a button”, not “menu locked”
local_ver="?"
[ -r "$VERSION_FILE" ] && local_ver="$(tr -d '[:space:]' < "$VERSION_FILE")"
remote_ver=""
[ -r "$STATE_DIR/update-available" ] && remote_ver="$(tr -d '[:space:]' < "$STATE_DIR/update-available")"
echo "Power: $([ "$on_ac" -eq 1 ] && echo 'AC' || echo 'Battery') · ${pct:-?} | color=#8e8e93 size=12"
echo "Mode: $mode · Thermal: $therm_name ($therm) | color=#8e8e93 size=12"
echo "Version: $local_ver | color=#8e8e93 size=12"
echo "---"
echo "Keep-awake mode | size=12 color=#e0902a"
mark() { [ "$mode" = "$1" ] && printf '✓ ' || printf '     '; }
echo "$(mark off)💤  Off (normal sleep) | bash='$SELF' param1=set param2=off terminal=false refresh=true"
echo "$(mark ac)🥚  On — while plugged in only | bash='$SELF' param1=set param2=ac terminal=false refresh=true"
echo "$(mark batt:50)🥓  On — while AC or battery ≥ 50% | bash='$SELF' param1=set param2=batt:50 terminal=false refresh=true"
echo "$(mark on)☕️  On — always | bash='$SELF' param1=set param2=on terminal=false refresh=true"
echo "---"
echo "Thermal pause threshold | size=12 color=#e0902a"
mark_t() { [ "$max_therm" = "$1" ] && printf '✓ ' || printf '     '; }
echo "$(mark_t 1)🌡️  Fair | bash='$SELF' param1=set-therm param2=1 terminal=false refresh=true"
echo "$(mark_t 2)♨️  Serious (default) — may hit during heavy workloads | bash='$SELF' param1=set-therm param2=2 terminal=false refresh=true"
echo "$(mark_t 3)🔥  Critical — for sustained high heat | bash='$SELF' param1=set-therm param2=3 terminal=false refresh=true"
echo "---"
if [ -n "$remote_ver" ]; then
  echo "⬆ Update WakeyWakey ($local_ver → $remote_ver) | bash='$SELF' param1=update terminal=true refresh=true color=#e0902a"
else
  echo "Check for update | bash='$SELF' param1=check-update terminal=false refresh=true"
fi
echo "View log | bash=/usr/bin/tail param1=-n param2=40 param3=/var/log/wakeywakey.log terminal=true"
echo "Refresh | refresh=true"
EOF
chmod +x "$PLUGIN"
# Clear quarantine on the plugin too (SwiftBar may refuse otherwise)
xattr -d com.apple.quarantine "$PLUGIN" 2>/dev/null || true
echo "• Plugin written: $PLUGIN"

# 6) root daemon
echo "• Installing keep-awake daemon (admin password may be required)…"
setup_sudo
run_sudo install -d -m 755 /usr/local/bin
run_sudo install -m 755 -o root -g wheel "$TMP_RECONCILE" "$RECONCILE_BIN"
run_sudo install -m 644 -o root -g wheel "$TMP_PLIST" "$PLIST"
run_sudo launchctl bootout system/local.wakeywakey 2>/dev/null || true
run_sudo launchctl bootstrap system "$PLIST"
run_sudo launchctl enable system/local.wakeywakey
cleanup_askpass
echo "✓ Daemon local.wakeywakey loaded"

# 7) launch / refresh SwiftBar
open -a SwiftBar 2>/dev/null || true
sleep 1
open "swiftbar://refreshallplugins" 2>/dev/null || true

# Also register as a Login Item via System Events when possible (complements defaults)
osascript >/dev/null 2>&1 <<'APPLESCRIPT' || true
tell application "System Events"
  if not (exists login item "SwiftBar") then
    make new login item at end of login items with properties {path:"/Applications/SwiftBar.app", hidden:false}
  end if
end tell
APPLESCRIPT

trap - EXIT

echo ""
echo "══════════════════════════════════════════════"
echo "✓ WakeyWakey ready."
echo "  Look for 💤 / 🥚 / 🥓 / ☕️ / 🔥 in the menu bar and pick a mode."
echo "  Default is Off until you choose. 🔥 = paused because the Mac is hot."
echo "  Re-run this file any time — it is safe and keeps your mode."
echo "  Uninstall:  bash \"$SCRIPT_PATH\" --uninstall"
echo "══════════════════════════════════════════════"
echo ""
echo "Note: macOS may ask once to allow Background Items for SwiftBar"
echo "      or the wakeywakey daemon — choose Allow if prompted."
pause
