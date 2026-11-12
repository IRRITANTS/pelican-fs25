#!/bin/bash
# FS25 dedicated server runner for Pelican/Wings.
# Modes (SERVER_MODE): install | server | web_only. All settings come from env (egg variables).
set -u
shopt -u patsub_replacement 2>/dev/null || true
ulimit -c 0    # crashing wine processes would dump core into /tmp/.wine-*, a small tmpfs under Wings

READY_MARKER="[pelican] FS25 server is running"

log()  { echo "[pelican] $*"; }
warn() { echo "[pelican] WARN: $*"; }
die()  { echo "[pelican] ERROR: $*"; exit 1; }

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
export HOME=/home/container
export USER=nobody          # Wine profile dir name: drive_c/users/nobody
export DISPLAY=:0
export WINEDEBUG=-all
export WINEPREFIX="$HOME/.fs25server"
export WINEARCH=win64
export WINEDLLOVERRIDES=mscoree=d
export TMPDIR="$HOME/tmp"

SERVER_MODE="${SERVER_MODE:-install}"
SERVER_NAME="${SERVER_NAME:-FS25 Server}"
SERVER_PASSWORD="${SERVER_PASSWORD:-}"
SERVER_ADMIN="${SERVER_ADMIN:-}"
SERVER_PLAYERS="${SERVER_PLAYERS:-16}"
SERVER_PORT="${SERVER_PORT:-10823}"
SERVER_REGION="${SERVER_REGION:-en}"
SERVER_MAP="${SERVER_MAP:-MapUS}"
SERVER_DIFFICULTY="${SERVER_DIFFICULTY:-3}"
SERVER_PAUSE="${SERVER_PAUSE:-2}"
SERVER_SAVE_INTERVAL="${SERVER_SAVE_INTERVAL:-180.000000}"
SERVER_STATS_INTERVAL="${SERVER_STATS_INTERVAL:-31536000}"
SERVER_CROSSPLAY="${SERVER_CROSSPLAY:-true}"
WEB_USERNAME="${WEB_USERNAME:-admin}"
WEB_PASSWORD="${WEB_PASSWORD:-}"
WEB_PORT="${WEB_PORT:-7999}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
VNC_PORT="${VNC_PORT:-6080}"
VNC_GEOMETRY="${VNC_GEOMETRY:-1280x800}"
ENABLE_VNC="${ENABLE_VNC:-false}"
STOP_TIMEOUT="${STOP_TIMEOUT:-180}"
SAVE_ON_STOP="${SAVE_ON_STOP:-false}"
SAVE_TIMEOUT="${SAVE_TIMEOUT:-180}"
GAME_LOG="${GAME_LOG:-filtered}"
export SERVER_DLC="${SERVER_DLC:-none}"       # DLC activated on autostart: all | none | name,name
WEB_START_TIMEOUT="${WEB_START_TIMEOUT:-240}"
GAME_START_TIMEOUT="${GAME_START_TIMEOUT:-600}"

GAME_SOURCE="${GAME_SOURCE:-giants}"
STEAM_LOGIN_WAIT="${STEAM_LOGIN_WAIT:-180}"     # s before a saved login is considered expired (noVNC is opened)
STEAM_SETTLE="${STEAM_SETTLE:-30}"              # s after login for Steam to notice a game update
STEAM_UPDATE_STALL="${STEAM_UPDATE_STALL:-900}" # s without download progress before an installed game is started anyway

CONFIG_DIR="$HOME/config/FarmingSimulator2025"      # saves, mods, licence, DLC (both game sources)
if [[ "$GAME_SOURCE" == steam ]]; then
  # Steam copy: Steam client + game live in their own prefix
  export WINEPREFIX="$HOME/steam-prefix"
  STEAM_DIR="$WINEPREFIX/drive_c/Program Files (x86)/Steam"
  STEAM_EXE="$STEAM_DIR/steam.exe"
  STEAM_ARGS=(-no-cef-sandbox -cef-disable-gpu -cef-disable-gpu-compositing -nofriendsui -nochatui)
  STEAM_SETUP_URL="https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe"
  WINE_GAME_DIR=""                                  # resolved by find_steam_game
  GAME_DIR=""
else
  GAME_DIR="$HOME/game/Farming Simulator 2025"
  WINE_GAME_DIR="$WINEPREFIX/drive_c/Program Files (x86)/Farming Simulator 2025"   # link -> GAME_DIR
fi
PROFILE_DIR="$WINEPREFIX/drive_c/users/$USER/Documents/My Games/FarmingSimulator2025"   # link -> CONFIG_DIR
GAME_LOG_DIR="$PROFILE_DIR/dedicated_server/logs"
TEMPLATE_DIR=/usr/local/share/fs25-pelican/templates  # fallback config templates (read-only)
BUILD_DIR="$HOME/.build/fs25"                       # configs generated from the variables
STATE_DIR="$HOME/config/.pelican"
LOGS="$HOME/logs"

CHILD_PIDS=()
WEB_PID=""
STOPPING=0

is_true() { case "${1,,}" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac; }
is_int()  { [[ "$1" =~ ^[0-9]+$ ]]; }
is_num()  { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }

# ---------------------------------------------------------------------------
# Validation and secrets
# ---------------------------------------------------------------------------
validate() {
  case "$SERVER_MODE" in install|server|web_only) ;; *) die "SERVER_MODE must be install, server or web_only (got '$SERVER_MODE')" ;; esac
  case "$GAME_SOURCE" in giants|steam) ;; *) die "GAME_SOURCE must be giants or steam (got '$GAME_SOURCE')" ;; esac
  for v in SERVER_PORT WEB_PORT VNC_PORT SERVER_PLAYERS SERVER_DIFFICULTY SERVER_PAUSE; do
    is_int "${!v}" || die "$v must be an integer (got '${!v}')"
  done
  for v in SERVER_SAVE_INTERVAL SERVER_STATS_INTERVAL; do
    is_num "${!v}" || die "$v must be numeric (got '${!v}')"
  done
  [[ "$WEB_PORT" != "$SERVER_PORT" ]] || die "the server's main allocation ($SERVER_PORT) is the game port and WEB_PORT is the same.
  The game needs its own main allocation (e.g. 10823), the web admin and noVNC two additional ones:
  set WEB_PORT and VNC_PORT (Startup tab) to the numbers of the additional allocations"
  [[ "$VNC_PORT" != "$SERVER_PORT" && "$VNC_PORT" != "$WEB_PORT" ]] || die "VNC_PORT ($VNC_PORT) must differ from the game port (main allocation $SERVER_PORT) and WEB_PORT ($WEB_PORT)"
  [[ "$VNC_PORT" != 5900 ]] || die "VNC_PORT 5900 is used internally by Xvnc, pick another allocation"
  for v in SAVE_TIMEOUT STEAM_LOGIN_WAIT STEAM_SETTLE STEAM_UPDATE_STALL; do
    is_int "${!v}" || die "$v must be an integer (got '${!v}')"
  done
  case "$GAME_LOG" in filtered|all|off) ;; *) die "GAME_LOG must be filtered, all or off (got '$GAME_LOG')" ;; esac
  [[ "$SERVER_DLC" =~ ^[A-Za-z0-9_.,\ -]*$ ]] || die "SERVER_DLC must be all, none or a comma separated list of DLC names (got '$SERVER_DLC')"
  case "${SERVER_CROSSPLAY,,}" in true|false) SERVER_CROSSPLAY="${SERVER_CROSSPLAY,,}" ;; *) die "SERVER_CROSSPLAY must be true or false" ;; esac
}

# Empty password variables get a random value, stored on the volume (never printed).
ensure_secret() {
  local var=$1 len=$2 file="$STATE_DIR/generated-secrets.env" val
  [[ -n "${!var}" ]] && return
  val=$(grep -E "^${var}=[A-Za-z0-9]+$" "$file" 2>/dev/null | tail -n1 | cut -d= -f2)
  if [[ -z "$val" ]]; then
    val=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len")
    ( umask 077; echo "${var}=${val}" >>"$file" )
    log "$var is empty: generated a random value and saved it to config/.pelican/generated-secrets.env"
  fi
  printf -v "$var" '%s' "$val"
}

# ---------------------------------------------------------------------------
# Config generation
# ---------------------------------------------------------------------------
one_line()   { printf '%s' "$1" | tr -d '\r' | tr '\n' ' '; }
xml_escape() { one_line "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"; }
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

set_tag() {
  local file=$1 tag=$2 val
  val=$(sed_escape "$(xml_escape "$3")")
  if ! grep -q "<$tag>" "$file"; then
    warn "tag <$tag> not found in $(basename "$file"), value not applied"
    return
  fi
  sed -i "s|<$tag>[^<]*</$tag>|<$tag>$val</$tag>|" "$file"
}

get_tag() { sed -n "s|.*<$2>\([^<]*\)</$2>.*|\1|p" "$1" 2>/dev/null | head -n1; }

report_changes() {
  local old=$1 new=$2 tag o n changed=0
  [[ -f "$old" ]] || return
  for tag in "${@:3}"; do
    o=$(get_tag "$old" "$tag"); n=$(get_tag "$new" "$tag")
    [[ "$o" == "$n" ]] && continue
    changed=1
    case "$tag" in
      *password*|passphrase) log "config change: <$tag> (hidden)" ;;
      *) log "config change: <$tag> '$o' -> '$n'" ;;
    esac
  done
  [[ $changed -eq 1 ]] || log "config unchanged since last start: $(basename "$new")"
}

generate_configs() {
  local srv="$BUILD_DIR/default_dedicatedServer.xml" cfg="$BUILD_DIR/default_dedicatedServerConfig.xml"
  mkdir -p "$BUILD_DIR"
  [[ -f "$srv" ]] && cp -f "$srv" "$TMPDIR/prev_server.xml"
  [[ -f "$cfg" ]] && cp -f "$cfg" "$TMPDIR/prev_config.xml"
  cp -f "$TEMPLATE_DIR/dedicatedServer.xml" "$srv"
  cp -f "$TEMPLATE_DIR/dedicatedServerConfig.xml" "$cfg"
  chmod 600 "$srv" "$cfg"

  sed -i "s|<webserver port=\"[0-9]*\"|<webserver port=\"$WEB_PORT\"|" "$srv"
  set_tag "$srv" username   "$WEB_USERNAME"
  set_tag "$srv" passphrase "$WEB_PASSWORD"

  set_tag "$cfg" game_name           "$SERVER_NAME"
  set_tag "$cfg" admin_password      "$SERVER_ADMIN"
  set_tag "$cfg" game_password       "$SERVER_PASSWORD"
  set_tag "$cfg" max_player          "$SERVER_PLAYERS"
  set_tag "$cfg" port                "$SERVER_PORT"
  set_tag "$cfg" language            "$SERVER_REGION"
  set_tag "$cfg" auto_save_interval  "$SERVER_SAVE_INTERVAL"
  set_tag "$cfg" stats_interval      "$SERVER_STATS_INTERVAL"
  set_tag "$cfg" crossplay_allowed   "$SERVER_CROSSPLAY"
  set_tag "$cfg" pause_game_if_empty "$SERVER_PAUSE"
  set_tag "$cfg" mapID               "$SERVER_MAP"
  set_tag "$cfg" economicDifficulty  "$SERVER_DIFFICULTY"

  report_changes "$TMPDIR/prev_server.xml" "$srv" username passphrase
  report_changes "$TMPDIR/prev_config.xml" "$cfg" game_name admin_password game_password max_player port \
    language auto_save_interval stats_interval crossplay_allowed pause_game_if_empty mapID economicDifficulty
  rm -f "$TMPDIR/prev_server.xml" "$TMPDIR/prev_config.xml"
  log "generated dedicatedServer.xml (web port $WEB_PORT) and dedicatedServerConfig.xml (game port $SERVER_PORT)"
}

# ---------------------------------------------------------------------------
# Processes
# ---------------------------------------------------------------------------
bg() { "$@" </dev/null & CHILD_PIDS+=("$!"); }

port_open() { timeout 2 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

container_ips() { ip -4 -o addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}'; }

# start_x vnc|auth|local: vnc = password + noVNC now, auth = password (noVNC can be started later
# with start_novnc), local = no password, never exposed (display for wine only)
start_x() {
  local args=(:0 -depth 24 -geometry "$VNC_GEOMETRY" -rfbport 5900 -localhost -AlwaysShared)
  mkdir -p /tmp/xkb "$HOME/.vnc"
  rm -rf /tmp/.X0-lock /tmp/.X11-unix/X0
  if [[ $1 == vnc || $1 == auth ]]; then
    ensure_secret VNC_PASSWORD 8
    (( ${#VNC_PASSWORD} >= 6 )) || die "VNC_PASSWORD must be at least 6 characters"
    (( ${#VNC_PASSWORD} <= 8 )) || warn "VNC_PASSWORD is longer than 8 characters; VNC auth only uses the first 8"
    ( umask 077; printf '%s\n' "$VNC_PASSWORD" | vncpasswd -f >"$HOME/.vnc/passwd" ) || die "vncpasswd failed"
    args+=(-SecurityTypes VncAuth -PasswordFile "$HOME/.vnc/passwd")
  else
    args+=(-SecurityTypes None)    # bound to localhost only, display for wine
  fi
  bg Xvnc "${args[@]}" >>"$LOGS/xvnc.log" 2>&1
  for _ in $(seq 1 30); do [[ -S /tmp/.X11-unix/X0 ]] && break; sleep 0.5; done
  [[ -S /tmp/.X11-unix/X0 ]] || die "Xvnc did not start, see logs/xvnc.log"
  log "X display :0 is up"
  X_AUTH=$1
  [[ $1 == vnc ]] && start_novnc
}

NOVNC_PID=""
start_novnc() {
  [[ -n "$NOVNC_PID" ]] && kill -0 "$NOVNC_PID" 2>/dev/null && return 0
  [[ "${X_AUTH:-}" == local ]] && die "refusing to expose a VNC display without a password"
  bg websockify --web /usr/share/novnc/ "$VNC_PORT" localhost:5900 >>"$LOGS/novnc.log" 2>&1
  NOVNC_PID=$!
  log "noVNC listening on port $VNC_PORT: http://${PUBLIC_HOST}:${VNC_PORT}/vnc.html?resize=remote&autoconnect=1"
}

stop_novnc() {
  [[ -n "$NOVNC_PID" ]] || return 0
  kill "$NOVNC_PID" 2>/dev/null
  NOVNC_PID=""
  log "noVNC closed (set ENABLE_VNC=true to keep it open)"
}

start_desktop() {
  mkdir -p "$HOME/Desktop" "$HOME/.config"
  rm -f "$HOME/Desktop/StartServer.desktop" "$HOME/Desktop/Webpanel.desktop" "$HOME/Desktop/Setup.desktop" \
    "$HOME/Desktop/GiantsDownload.desktop"
  if [[ "$GAME_SOURCE" == steam ]]; then
    rm -f "$HOME/Desktop/FS25-Setup.desktop"
    cat >"$HOME/Desktop/Steam.desktop" <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Steam (install / login)
Comment=Installs Steam on first run, then starts it: log in and install Farming Simulator 25
Exec=xfce4-terminal --hold --title "Steam" -x /usr/local/bin/fs25-pelican steam-gui
Terminal=false
StartupNotify=false
EOF
    chmod +x "$HOME/Desktop/"*.desktop
    bg dbus-run-session -- startxfce4 >>"$LOGS/xfce.log" 2>&1
    return
  fi
  cat >"$HOME/Desktop/FS25-Setup.desktop" <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Setup / Update FS25
Comment=Install or update Farming Simulator 25 and DLC from installer/ and dlc/
Exec=xfce4-terminal --hold --title "FS25 Setup" -x /usr/local/bin/fs25-pelican giants-setup
Terminal=false
StartupNotify=false
EOF
  chmod +x "$HOME/Desktop/"*.desktop
  bg dbus-run-session -- startxfce4 >>"$LOGS/xfce.log" 2>&1
}

game_installed() { [[ -n "$GAME_DIR" && -f "$GAME_DIR/dedicatedServer.exe" ]]; }

# link_dir <dir on the volume> <path inside the wine prefix>
link_dir() {
  mkdir -p "$1" "$(dirname "$2")"
  if [[ -L "$2" ]]; then
    ln -sfn "$1" "$2"
  elif [[ -e "$2" ]]; then
    warn "${2#$HOME/} is a real directory, expected a link to ${1#$HOME/}"
  else
    ln -s "$1" "$2"
  fi
}

new_prefix() {
  [[ -f "$WINEPREFIX/system.reg" ]] && return 0
  log "creating wine prefix (${WINEPREFIX#$HOME/}/)..."
  wineboot -i </dev/null >>"$LOGS/wine.log" 2>&1
  wineserver -w
}

# ---------------------------------------------------------------------------
# GIANTS copy (GAME_SOURCE=giants): game in game/, licence, saves and DLC in config/
# ---------------------------------------------------------------------------
giants_prefix() {
  new_prefix
  link_dir "$GAME_DIR" "$WINE_GAME_DIR"
  link_dir "$CONFIG_DIR" "$PROFILE_DIR"
  mkdir -p "$GAME_LOG_DIR"
}

has_licence() { compgen -G "$CONFIG_DIR/*.dat" >/dev/null; }

install_dlc() {
  local f name found=0
  shopt -s nullglob nocaseglob
  for f in "$HOME"/dlc/FarmingSimulator25_*.exe; do
    found=1
    name=$(basename "$f"); name=${name#FarmingSimulator25_}; name=${name%%_*}
    if [[ -f "$CONFIG_DIR/pdlc/$name.dlc" ]]; then log "DLC $name is installed"; continue; fi
    log "installing DLC $name ($(basename "$f"))..."
    wine "$f"; wineserver -w
    if [[ -f "$CONFIG_DIR/pdlc/$name.dlc" ]]; then log "DLC $name installed"; else warn "DLC $name: installer finished, but pdlc/$name.dlc is missing"; fi
  done
  shopt -u nullglob nocaseglob
  (( found )) || log "no DLC installers (FarmingSimulator25_<name>_*.exe) in dlc/"
}

# desktop launcher "Setup / Update FS25": install game, activate the licence, install DLC, update
giants_setup() {
  local installer="" f exe="$WINE_GAME_DIR/FarmingSimulator2025.exe"
  for f in "$HOME/installer/FarmingSimulator2025.exe" "$HOME/installer/Setup.exe"; do
    [[ -f "$f" ]] && { installer=$f; break; }
  done
  giants_prefix
  if game_installed; then
    log "the game is installed in game/"
  else
    [[ -n "$installer" ]] || die "no installer: put Setup.exe (or the game image, then press Reinstall) into installer/"
    local free; free=$(df -Pk "$HOME" | awk 'NR==2 {print int($4 / 1048576)}')
    (( free >= 50 )) || die "only ${free} GB free on the volume, the game needs about 50 GB"
    log "installing the game into game/ ..."
    wine "$installer" /SILENT /NOCANCEL /NOICONS; wineserver -w
    game_installed || die "the installer finished, but game/Farming Simulator 2025/dedicatedServer.exe is missing"
  fi
  if ! has_licence; then
    log "starting the game once to activate it: enter the product key when asked, then close the game"
    wine "$exe"; wineserver -w
    has_licence || die "no licence files (*.dat) in config/FarmingSimulator2025: the product key was not accepted"
  fi
  install_dlc
  log "starting the game to check for updates: answer 'No' to a GPU driver warning, close the game in the main menu"
  wine "$exe"; wineserver -w
  # DLC check the game version against this file
  [[ -f "$GAME_DIR/VERSION" ]] && cp -f "$GAME_DIR/VERSION" "$CONFIG_DIR/"
  rm -f "$HOME/Desktop/"Farming*.desktop "$HOME/Desktop/"Farming*.lnk
  log "setup finished. Set SERVER_MODE=server in the panel and restart the server."
}

# dedicatedServer.xml in the game dir: the game's own file is the template, only port and credentials change
write_server_xml() {
  local srv="$GAME_DIR/dedicatedServer.xml"
  [[ -f "$srv.pelican-orig" ]] || cp -f "$srv" "$srv.pelican-orig" 2>/dev/null \
    || cp -f "$TEMPLATE_DIR/dedicatedServer.xml" "$srv.pelican-orig"
  cp -f "$srv.pelican-orig" "$srv"
  sed -i "s|<webserver port=\"[0-9]*\"|<webserver port=\"$WEB_PORT\"|" "$srv"
  set_tag "$srv" username   "$WEB_USERNAME"
  set_tag "$srv" passphrase "$WEB_PASSWORD"
  mkdir -p "$PROFILE_DIR/dedicated_server/logs"
  cp -f "$BUILD_DIR/default_dedicatedServerConfig.xml" "$PROFILE_DIR/dedicated_server/dedicatedServerConfig.xml"
}

# ---------------------------------------------------------------------------
# Steam copy (GAME_SOURCE=steam)
# ---------------------------------------------------------------------------
find_steam_game() {
  local exe
  exe=$(find "$STEAM_DIR/steamapps/common" -maxdepth 2 -iname dedicatedServer.exe 2>/dev/null | head -n1)
  [[ -n "$exe" ]] || return 1
  GAME_DIR=$(dirname "$exe")
  WINE_GAME_DIR="$GAME_DIR"
}

steam_prefix() {
  new_prefix
  # saves, mods and licence data stay in config/FarmingSimulator2025, like the GIANTS layout
  link_dir "$CONFIG_DIR" "$PROFILE_DIR"
  mkdir -p "$GAME_LOG_DIR"
}

# the installer writes Steam.exe; the client may later rename it, so match case-insensitively
steam_installed() {
  local exe
  exe=$(find "$STEAM_DIR" -maxdepth 1 -iname steam.exe 2>/dev/null | head -n1)
  [[ -n "$exe" ]] && STEAM_EXE="$exe"
}

install_steam_client() {
  steam_installed && return 0
  local setup="$HOME/installer/SteamSetup.exe"
  if [[ ! -f "$setup" ]]; then
    log "downloading SteamSetup.exe..."
    curl -fsSL --retry 3 -o "$TMPDIR/SteamSetup.exe" "$STEAM_SETUP_URL" || die "download of SteamSetup.exe failed"
    setup="$TMPDIR/SteamSetup.exe"
  fi
  log "installing Steam into steam-prefix/ ..."
  wine "$setup" /S </dev/null >>"$LOGS/steam.log" 2>&1
  wineserver -w
  steam_installed || die "Steam installation failed, see logs/steam.log"
}

# desktop launcher in install mode: install Steam once, then run it in the foreground
steam_gui() {
  steam_prefix
  install_steam_client
  log "starting Steam. Log in with the server's Steam account and tick 'Remember me'."
  log "SERVER_MODE=server does the rest by itself (game download, updates, start); this mode is only for manual work."
  exec wine "$STEAM_EXE" "${STEAM_ARGS[@]}"
}

STEAM_APPID=2300320
STEAM_ACF="${STEAM_DIR:-}/steamapps/appmanifest_$STEAM_APPID.acf"

acf_get() { sed -n "s/^[[:space:]]*\"$1\"[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$STEAM_ACF" 2>/dev/null | head -n1; }

steam_log_size() { stat -c %s "$STEAM_DIR/logs/$1" 2>/dev/null || echo 0; }

# Steam log lines appended after the log had $2 bytes (the whole file if Steam rotated it).
# Byte offsets, not timestamps: Steam logs in UTC, the container clock may use the panel's TZ.
steam_log_since() {
  local f="$STEAM_DIR/logs/$1"
  if (( $(steam_log_size "$1") < $2 )); then cat "$f" 2>/dev/null; else tail -c +"$(( $2 + 1 ))" "$f" 2>/dev/null; fi
}

steam_logged_on() { steam_log_since connection_log.txt "$1" | grep -q '\[Logged On,.*RecvMsgClientLogOnResponse() : processing complete'; }

# a manifest with "update required" makes the logged-in client download the game, no clicks needed
queue_game_install() {
  [[ -f "$STEAM_ACF" ]] && return 0
  mkdir -p "$STEAM_DIR/steamapps/common"
  log "Farming Simulator 25 is not installed yet: Steam will download it after logging in (~41 GB)"
  printf '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"Universe"\t\t"1"\n\t"name"\t\t"Farming Simulator 25"\n\t"StateFlags"\t\t"1026"\n\t"installdir"\t\t"Farming Simulator 25"\n}\n' \
    "$STEAM_APPID" >"$STEAM_ACF"
}

steam_login_prompt() {
  warn "Steam is not logged in (first start, or the saved login has expired)"
  start_novnc
  start_desktop
  bg wine "$STEAM_EXE" "${STEAM_ARGS[@]}" >>"$LOGS/steam.log" 2>&1   # shows the running client's login window
  log "open noVNC: http://${PUBLIC_HOST}:${VNC_PORT}/vnc.html?resize=remote&autoconnect=1"
  log "  VNC password: VNC_PASSWORD in the panel (if empty: config/.pelican/generated-secrets.env)"
  log "  log in with the server's Steam account, tick 'Remember me', confirm Steam Guard. Nothing else to click:"
  log "  the server continues by itself (game download, start)."
}

wait_steam_login() {
  local since=$1 waited=0 prompted=0 patience=$STEAM_LOGIN_WAIT
  # no remembered account at all: ask right away (Steam still needs ~30 s to show its window);
  # otherwise give the client time for a self-update before assuming the saved login is gone
  grep -qs '"RememberPassword"[[:space:]]*"1"' "$STEAM_DIR/config/loginusers.vdf" || patience=30
  until steam_logged_on "$since"; do
    if (( ! prompted && waited >= patience )); then
      prompted=1; steam_login_prompt
    elif (( prompted && waited % 300 == 0 )); then
      log "still waiting for the Steam login over noVNC..."
    fi
    wait_cmd 3; waited=$((waited + 3))
  done
  log "Steam: logged in"
  if (( prompted )) && ! is_true "$ENABLE_VNC"; then stop_novnc; fi
}

gib() { awk -v b="${1:-0}" 'BEGIN { printf "%.1f", b / 1073741824 }'; }

download_progress() {
  local done=${1:-0} total=${2:-0} n bar rest
  if (( total > 0 )); then
    (( done > total )) && done=$total
    n=$(( done * 30 / total ))
    printf -v bar '%*s' "$n" ''; bar=${bar// /#}
    printf -v rest '%*s' $(( 30 - n )) ''; bar+=${rest// /.}
    log "downloading Farming Simulator 25 [$bar] $(( done * 100 / total ))%  $(gib "$done") / $(gib "$total") GB"
  else
    log "Steam is preparing the download/update (state $3)..."
  fi
}

# wait until Steam reports the game as fully installed and up to date (StateFlags 4), with a progress bar
wait_game_ready() {
  wait_cmd "$STEAM_SETTLE"   # Steam checks for updates right after logging in
  local flags done total staged tostage last=-1 still=0 dl="$STEAM_DIR/steamapps/downloading/$STEAM_APPID"
  while :; do
    flags=$(acf_get StateFlags)
    [[ "$flags" == 4 ]] && break
    done=$(acf_get BytesDownloaded); total=$(acf_get BytesToDownload)
    staged=$(acf_get BytesStaged); tostage=$(acf_get BytesToStage)
    done=${done:-0} total=${total:-0} staged=${staged:-0} tostage=${tostage:-0}
    # the manifest is rewritten rarely. Steam unpacks into the download folder, whose files are created at full
    # size first (preallocation), so count the blocks really written, against the unpacked size
    if [[ -d "$dl" ]] && (( tostage > 0 )); then
      local onDisk; onDisk=$(du -s --block-size=1 "$dl" 2>/dev/null | cut -f1)
      (( ${onDisk:-0} > staged )) && staged=$onDisk
    fi
    if (( tostage > 0 )); then
      done=$staged; total=$tostage
    fi
    download_progress "$done" "$total" "$flags"
    if [[ "$done" == "$last" ]]; then still=$((still + 15)); else still=0; last=$done; fi
    if (( still >= STEAM_UPDATE_STALL )); then
      if find_steam_game; then
        warn "the Steam update has not progressed for ${still}s (state $flags); starting the installed version"
        break
      fi
      warn "the Steam download has not progressed for ${still}s (state $flags); still waiting (see logs in steam-prefix/.../Steam/logs/content_log.txt)"
      still=0
    fi
    wait_cmd 15
  done
  find_steam_game || die "Steam reports Farming Simulator 25 as installed, but dedicatedServer.exe was not found"
  log "Farming Simulator 25 is installed and up to date (build $(acf_get buildid))"
}

# server mode: install Steam if needed, log in (saved login, or once over noVNC), install/update the game
start_steam() {
  install_steam_client
  queue_game_install
  local since; since=$(steam_log_size connection_log.txt)
  log "starting Steam in the background..."
  bg wine "$STEAM_EXE" -silent "${STEAM_ARGS[@]}" >>"$LOGS/steam.log" 2>&1
  # Steam's own download/update messages for the game
  ( for _ in $(seq 1 60); do [[ -f "$STEAM_DIR/logs/content_log.txt" ]] && break; sleep 2; done
    tail -n0 -F "$STEAM_DIR/logs/content_log.txt" 2>/dev/null \
      | grep --line-buffered -E "AppID $STEAM_APPID (update|state changed|scheduler)" | sed -u 's/^/[steam] /' ) </dev/null &
  CHILD_PIDS+=("$!")
  wait_steam_login "$since"
  wait_game_ready
  log "Steam is running"
}

prepare_steam_game() {
  find_steam_game || die "Farming Simulator 25 not found in the Steam library. Set SERVER_MODE=install and install it via Steam"
  log "Steam game dir: ${GAME_DIR#$WINEPREFIX/}"
  write_server_xml
  # without it the game relaunches itself through steam://run, and Steam waits for a hidden
  # "launch with these arguments?" confirmation; with it the game attaches to the running client
  local d
  for d in "$GAME_DIR" "$GAME_DIR/x64"; do
    [[ -d "$d" ]] && echo 2300320 >"$d/steam_appid.txt"
  done
}

prepare_game() {
  game_installed || die "game is not installed in game/. Set SERVER_MODE=install, restart and run 'Setup / Update FS25' over noVNC"
  giants_prefix
  write_server_xml
  has_licence || warn "no licence files (*.dat) in config/FarmingSimulator2025, the server will likely refuse to start"
}

start_webadmin() {
  log "starting dedicatedServer.exe (web admin on port $WEB_PORT)..."
  ( cd "$WINE_GAME_DIR" && exec wine "$WINE_GAME_DIR/dedicatedServer.exe" ) </dev/null >>"$LOGS/wine.log" 2>&1 &
  WEB_PID=$!
  CHILD_PIDS+=("$WEB_PID")

  local ip bound="" waited=0
  while [[ -z "$bound" ]]; do
    kill -0 "$WEB_PID" 2>/dev/null || die "dedicatedServer.exe exited during startup, see logs/wine.log"
    (( waited >= WEB_START_TIMEOUT )) && die "web admin did not open port $WEB_PORT within ${WEB_START_TIMEOUT}s"
    for ip in $(container_ips); do port_open "$ip" "$WEB_PORT" && { bound=$ip; break; }; done
    [[ -n "$bound" ]] || { sleep 3; waited=$((waited + 3)); }
  done
  export WEBSERVER_LISTENING_ON="$bound"
  log "web admin is listening on $bound:$WEB_PORT"

  # the web admin binds one address: expose it on every container IP
  for ip in $(container_ips); do
    port_open "$ip" "$WEB_PORT" && continue
    log "forwarding $ip:$WEB_PORT -> $bound:$WEB_PORT"
    bg socat "tcp-listen:$WEB_PORT,reuseaddr,fork,bind=$ip" "tcp:$bound:$WEB_PORT" >>"$LOGS/socat.log" 2>&1
  done
}

game_pid() { pgrep -f 'FarmingSimulator2025Game\.exe' | head -n1; }

start_game() {
  log "logging into web admin and pressing Start..."
  local tries=0 deadline=$((SECONDS + GAME_START_TIMEOUT))
  until timeout 60 node /usr/local/bin/fs25-webadmin.mjs start </dev/null 2>&1 | sed -u 's/^/[autostart] /'; (( PIPESTATUS[0] == 0 )); do
    tries=$((tries + 1))
    (( SECONDS >= deadline )) && { warn "could not press Start after $tries tries; start the game manually in the web admin"; return 1; }
    wait_cmd 15
  done
  local waited=0
  until [[ -n "$(game_pid)" ]]; do
    (( waited >= 300 )) && { warn "FarmingSimulator2025Game.exe did not appear within 300s"; return 1; }
    sleep 3; waited=$((waited + 3))
  done
  log "game process started (pid $(game_pid))"
}

# The game (FarmingSimulator2025Game.exe) writes its own log: config/FarmingSimulator2025/log_<date>.txt,
# a new file on every game start (also Stop/Start in the web admin). Follow the newest one into the console
# as "[game] HH:MM:SS ...". GAME_LOG=filtered drops per-asset load timings and texture/config noise.
tail_game_log() {
  [[ "$GAME_LOG" == off ]] && return 0
  local drop='^[[:space:]]*$'
  [[ "$GAME_LOG" == filtered ]] \
    && drop=' \([0-9.]+ ms\)$|^([0-9:]{8})?[[:space:]]*(Register [A-Za-z]+ .[A-Za-z]|Info: Loaded fruit type)|Warning \(performance\)|^([0-9:]{8})?[[:space:]]*$'
  (
    local since=$(( $(date +%s) - 5 )) cur="" f="" tp=""
    while true; do
      f=$(ls -t "$CONFIG_DIR"/log_*.txt 2>/dev/null | head -n1)
      if [[ -n "$f" && "$f" != "$cur" ]] && (( $(stat -c %Y "$f") >= since )); then
        [[ -n "$tp" ]] && { pkill -TERM -P "$tp" 2>/dev/null; kill "$tp" 2>/dev/null; }
        cur=$f
        (
          tail -n +1 -F "$cur" 2>/dev/null \
            | sed -u -E 's/\r$//; s/^[0-9]{4}-[0-9]{2}-[0-9]{2} ([0-9:]{8})\.[0-9]+ /\1 /' \
            | grep --line-buffered -vE "$drop" | sed -u 's/^/[game] /'
        ) &
        tp=$!
      fi
      sleep 5
    done
  ) </dev/null &
  CHILD_PIDS+=("$!")
}

# older builds write server.log, current ones server_<date>.log created when dedicatedServer.exe starts
tail_logs() {
  mkdir -p "$GAME_LOG_DIR"
  local since=$(( $(date +%s) - 5 ))
  (
    f=""
    for _ in $(seq 1 90); do
      f=$(ls -t "$GAME_LOG_DIR"/server_*.log 2>/dev/null | head -n1)
      [[ -n "$f" ]] && (( $(stat -c %Y "$f") >= since )) && break
      f=""; sleep 2
    done
    exec tail -n +1 -F ${f:+"$f"} "$GAME_LOG_DIR/server.log" 2>/dev/null
  ) </dev/null &
  CHILD_PIDS+=("$!")
}

# ---------------------------------------------------------------------------
# Save on stop (FS25_PelicanSave mod; the web admin has no save button and Stop does not save)
# ---------------------------------------------------------------------------
SAVE_MOD_SRC=/usr/local/share/fs25-pelican/FS25_PelicanSave.zip
SAVE_MOD_DIR="$CONFIG_DIR/modSettings/FS25_PelicanSave"

install_save_mod() {
  export PELICAN_MOD=""
  local dst="$CONFIG_DIR/mods/FS25_PelicanSave.zip"
  if ! is_true "$SAVE_ON_STOP"; then
    [[ -f "$dst" ]] && rm -f "$dst" && log "SAVE_ON_STOP=false: removed FS25_PelicanSave from mods/"
    log "SAVE_ON_STOP=false: the game is not saved on stop, only by autosave"
    return 0
  fi
  [[ -f "$SAVE_MOD_SRC" ]] || { warn "save mod missing in the image, saving on stop is disabled"; return 0; }
  cmp -s "$SAVE_MOD_SRC" "$dst" || cp -f "$SAVE_MOD_SRC" "$dst"
  rm -f "$SAVE_MOD_DIR/status.xml" "$SAVE_MOD_DIR/request.xml"
  export PELICAN_MOD=FS25_PelicanSave.zip
}

save_status() { sed -n "s/.*<pelican[^>]* $1=\"\([^\"]*\)\".*/\1/p" "$SAVE_MOD_DIR/status.xml" 2>/dev/null | head -n1; }

newest_save_file() {
  find "$CONFIG_DIR"/savegame[0-9]* -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f1 | cut -d. -f1
}

# save_game: ask the mod to save, wait until it reports done and the savegame files stop changing
save_game() {
  [[ -n "${PELICAN_MOD:-}" && -n "$(game_pid)" ]] || return 1
  local state; state=$(save_status state)
  case "$state" in
    ready|done|error) ;;
    loading) log "the map is still loading, nothing to save yet"; return 1 ;;
    *) warn "save mod is not active in this game (no answer from it: still starting, or the mod was deactivated in the web admin)"; return 1 ;;
  esac
  local id before; id=$(date +%s%N); before=$(newest_save_file); before=${before:-0}
  log "saving the game..."
  printf '<?xml version="1.0" encoding="utf-8" standalone="no" ?>\n<pelican id="%s"/>\n' "$id" >"$SAVE_MOD_DIR/request.xml.tmp" \
    && mv -f "$SAVE_MOD_DIR/request.xml.tmp" "$SAVE_MOD_DIR/request.xml"
  local waited=0
  while (( waited < SAVE_TIMEOUT )); do
    if [[ "$(save_status id)" == "$id" ]]; then
      state=$(save_status state)
      [[ "$state" == done || "$state" == error ]] && break
    fi
    [[ -n "$(game_pid)" ]] || { warn "game exited while saving"; return 1; }
    sleep 1; waited=$((waited + 1))
  done
  rm -f "$SAVE_MOD_DIR/request.xml"
  if [[ "$(save_status id)" != "$id" ]]; then
    warn "the game did not answer the save request within ${SAVE_TIMEOUT}s"; return 1
  fi
  if [[ "$state" == error ]]; then
    warn "save failed: $(save_status info)"; return 1
  fi
  # files are written over a few frames: wait until they changed and then were quiet for 3 s (max 60 s)
  local t newest=0
  for t in $(seq 1 60); do
    newest=$(newest_save_file); newest=${newest:-0}
    (( newest > before && $(date +%s) - newest >= 3 )) && break
    sleep 1
  done
  if (( newest > before )); then
    log "game saved ($(( waited + t ))s)"
  else
    warn "the mod reported success, but no savegame file changed"; return 1
  fi
}

# ---------------------------------------------------------------------------
# Shutdown
# ---------------------------------------------------------------------------
shutdown_all() {
  local rc=${1:-0}
  (( STOPPING )) && return
  STOPPING=1
  log "stopping (mode $SERVER_MODE)..."

  if [[ -n "$(game_pid)" && -n "${WEBSERVER_LISTENING_ON:-}" ]]; then
    [[ -n "${PELICAN_MOD:-}" ]] && save_game
    log "asking web admin to stop the game..."
    timeout 60 node /usr/local/bin/fs25-webadmin.mjs stop </dev/null 2>&1 | sed -u 's/^/[webadmin] /'
    local waited=0
    while [[ -n "$(game_pid)" ]] && (( waited < STOP_TIMEOUT )); do sleep 2; waited=$((waited + 2)); done
    [[ -n "$(game_pid)" ]] && warn "game still running after ${STOP_TIMEOUT}s, killing wine"
  fi

  if [[ "$GAME_SOURCE" == steam ]] && pgrep -if 'steam\.exe' >/dev/null 2>&1; then
    log "shutting down Steam..."
    timeout 30 wine "$STEAM_EXE" -shutdown </dev/null >>"$LOGS/steam.log" 2>&1
    for _ in $(seq 1 20); do pgrep -if 'steam\.exe' >/dev/null 2>&1 || break; sleep 1; done
  fi
  if pgrep -f '\.exe' >/dev/null 2>&1; then
    wineserver -k 2>/dev/null || true
    sleep 2
  fi
  local p
  for p in "${CHILD_PIDS[@]}"; do kill -TERM "$p" 2>/dev/null; done
  for _ in $(seq 1 10); do
    local alive=0
    for p in "${CHILD_PIDS[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
    (( alive )) || break
    sleep 1
  done
  trap '' TERM INT
  kill -TERM 0 2>/dev/null   # anything left in our process group (xfce, dbus, tail)
  wait 2>/dev/null
  log "stopped."
  exit "$rc"
}

handle_command() {
  case "${1,,}" in
    stop|quit|exit) shutdown_all 0 ;;
    save)
      [[ -n "${PELICAN_MOD:-}" ]] || { log "saving needs SAVE_ON_STOP=true (FS25_PelicanSave mod)"; return; }
      save_game || true
      ;;
    status)
      log "mode=$SERVER_MODE web_pid=${WEB_PID:-none} game_pid=$(game_pid || true) save_mod=$(save_status state || true)"
      ;;
    "") ;;
    *) log "console commands: stop, save, status (game commands are available in the web admin)" ;;
  esac
}

STDIN_OPEN=1
IN_READ=0
STOP_REQUESTED=0
# TERM/INT: a trap that fires inside "read -t" is abandoned halfway when the read timeout expires,
# so while reading only a flag is set and wait_cmd shuts down after read returns
on_signal() {
  STOP_REQUESTED=1
  (( IN_READ )) || shutdown_all 0
}

# wait_cmd N: sleep N seconds while still handling console commands, so "stop" from the panel
# also works during long waits (Steam login, game download)
wait_cmd() {
  local end=$(( SECONDS + $1 )) line rc
  while (( SECONDS < end )); do
    if (( STDIN_OPEN )); then
      IN_READ=1
      IFS= read -r -t "$(( end - SECONDS ))" line; rc=$?
      IN_READ=0
      (( STOP_REQUESTED )) && shutdown_all 0
      if (( rc == 0 )); then
        handle_command "${line//$'\r'/}"
      elif (( rc <= 128 )); then
        STDIN_OPEN=0
      fi
    else
      sleep "$(( end - SECONDS ))"
      (( STOP_REQUESTED )) && shutdown_all 0
    fi
  done
}

# The game quits by itself when it loses the GIANTS master server; Stop pressed in the web admin
# ends the log without this error, so that case is left alone.
game_lost_master() {
  local f; f=$(ls -t "$CONFIG_DIR"/log_*.txt 2>/dev/null | head -n1)
  [[ -n "$f" ]] && tail -n 60 "$f" | grep -aq 'Lost connection to master server'
}

# The web admin fetches something from farming-simulator.com over plain http with no timeout; when that
# request gets no answer the login page hangs for everyone. Only the node can fix it (README: "Web admin hangs").
web_admin_hangs() {
  ! curl -s -m 20 -o /dev/null "http://${WEBSERVER_LISTENING_ON}:${WEB_PORT}/index.html"
}

main_loop() {
  local game_up=0 web_probe=$SECONDS web_fails=0
  while true; do
    wait_cmd 5
    if [[ -n "$WEB_PID" ]] && ! kill -0 "$WEB_PID" 2>/dev/null; then
      warn "dedicatedServer.exe exited unexpectedly"
      shutdown_all 1
    fi
    if [[ -n "$WEB_PID" && -n "${WEBSERVER_LISTENING_ON:-}" ]] && (( SECONDS - web_probe >= 300 )); then
      web_probe=$SECONDS
      if ! web_admin_hangs; then
        web_fails=0
      elif (( ++web_fails == 3 )); then
        warn "the web admin login page has not answered for 15 minutes (the game itself keeps running)."
        warn "  Usual cause: its http request to farming-simulator.com hangs. Fix on the node: README, section 'Web admin hangs'"
      fi
    fi
    [[ "$SERVER_MODE" == server && -n "$WEB_PID" ]] || continue
    if [[ -n "$(game_pid)" ]]; then
      game_up=1
    elif (( game_up )); then
      game_up=0
      if game_lost_master; then
        warn "the game shut itself down: lost connection to the GIANTS master server. Starting it again in 60 s"
        wait_cmd 60
        start_game && log "game restarted after the master server disconnect"
      fi
    fi
  done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
# desktop launchers (install mode)
case "${1:-}" in
  steam-gui)
    [[ "$GAME_SOURCE" == steam ]] || die "steam-gui needs GAME_SOURCE=steam"
    mkdir -p "$LOGS" "$TMPDIR"
    steam_gui
    ;;
  giants-setup)
    [[ "$GAME_SOURCE" == giants ]] || die "giants-setup needs GAME_SOURCE=giants"
    mkdir -p "$LOGS" "$TMPDIR"
    echo "===== $(date '+%F %T') setup started =====" | tee -a "$LOGS/setup.log"
    ( giants_setup ) 2>&1 | tee -a "$LOGS/setup.log"
    echo "===== $(date '+%F %T') setup finished (exit ${PIPESTATUS[0]}) =====" | tee -a "$LOGS/setup.log"
    exit 0
    ;;
esac

trap on_signal TERM INT
cd "$HOME" || exit 1
mkdir -p "$HOME"/{game,dlc,installer,config/FarmingSimulator2025/mods,tmp,logs} "$STATE_DIR"
chmod 700 "$STATE_DIR"

PUBLIC_HOST="${SERVER_IP:-<server-ip>}"
[[ "$PUBLIC_HOST" == 0.0.0.0 ]] && PUBLIC_HOST="<server-ip>"

validate
# wineserver keeps shared memory (tmpmap-*) in /tmp/.wine-$UID; Wings mounts /tmp as tmpfs (docker.tmpfs_size)
tmp_mb=$(df -Pm /tmp 2>/dev/null | awk 'NR==2 {print $2}')
if [[ -n "$tmp_mb" ]] && (( tmp_mb < 1000 )); then
  warn "/tmp is only ${tmp_mb} MB; wine stores shared memory there. Steam and the game need >= 1024 MB:"
  warn "set docker.tmpfs_size: 2048 in /etc/pelican/config.yml on the node and restart wings"
fi
ensure_secret WEB_PASSWORD 16
ensure_secret SERVER_ADMIN 12
export WEB_USERNAME WEB_PASSWORD WEB_PORT SERVER_PORT
generate_configs

case "$SERVER_MODE" in
  install)
    : >"$LOGS/setup.log"
    start_x vnc
    if [[ "$GAME_SOURCE" == steam ]]; then
      steam_prefix
      start_desktop
      log "install mode (Steam): open noVNC, double-click 'Steam (install / login)', log in, install Farming Simulator 25."
    else
      start_desktop
      log "install mode: open noVNC, double-click 'Setup / Update FS25' on the desktop."
      log "put the game image into installer/ and DLC files into dlc/ (SFTP or file manager) before running Setup."
    fi
    bg tail -n0 -F "$LOGS/setup.log"
    echo "$READY_MARKER (install mode, noVNC on port $VNC_PORT)"
    ;;
  server|web_only)
    if is_true "$ENABLE_VNC"; then start_x vnc
    elif [[ "$GAME_SOURCE" == steam ]]; then start_x auth     # noVNC opens only if the Steam login is needed
    else start_x local; fi
    if [[ "$GAME_SOURCE" == steam ]]; then
      steam_prefix
      start_steam
      prepare_steam_game
    else
      prepare_game
    fi
    install_save_mod
    tail_logs
    tail_game_log
    start_webadmin
    if [[ "$SERVER_MODE" == server ]]; then
      start_game && echo "$READY_MARKER (game port $SERVER_PORT, web admin port $WEB_PORT)"
    else
      echo "$READY_MARKER (web_only, web admin port $WEB_PORT)"
    fi
    log "web admin: http://${PUBLIC_HOST}:${WEB_PORT}/  (login: WEB_USERNAME / WEB_PASSWORD)"
    ;;
esac

main_loop
