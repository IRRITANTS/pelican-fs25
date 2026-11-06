#!/bin/bash
# FS25 (Pelican) install script. Runs as root in the installer container, volume at /mnt/server.
# Never deletes game, config or saves: safe to use with "Reinstall".
# Setup in the game container needs installer/Setup.exe (or FarmingSimulator2025.exe) and DLC as .exe,
# so archives (.img/.iso/.zip/.7z) found in installer/ and dlc/ are extracted here.
set -u
shopt -s nullglob nocaseglob
cd /mnt/server || exit 1

mkdir -p game dlc installer tmp logs config/FarmingSimulator2025/mods config/.pelican
echo "[install] folders ready: game/ dlc/ installer/ config/ (mods: config/FarmingSimulator2025/mods)"

need=""
command -v curl >/dev/null 2>&1 || need="$need curl ca-certificates"
command -v 7z >/dev/null 2>&1 || need="$need p7zip-full"
if [ -n "$need" ]; then
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $need >/dev/null \
    || { echo "[install] ERROR: could not install:$need"; exit 1; }
fi

if [ "${GAME_SOURCE:-giants}" = steam ]; then
  if [ -n "$(find steam-prefix/drive_c -maxdepth 3 -iname steam.exe 2>/dev/null | head -n1)" ]; then
    echo "[install] Steam is already installed in steam-prefix/ (login, game and saves are kept)."
    echo "[install] Game updates are installed automatically on every start (SERVER_MODE=server)."
    exit 0
  fi
  if [ ! -f installer/SteamSetup.exe ]; then
    echo "[install] downloading SteamSetup.exe (official Valve CDN)..."
    curl -fL --retry 3 -s -o installer/SteamSetup.exe.part https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe \
      && mv installer/SteamSetup.exe.part installer/SteamSetup.exe \
      || { echo "[install] WARN: download failed, the Steam icon will retry it"; rm -f installer/SteamSetup.exe.part; }
  fi
  echo "[install] GAME_SOURCE=steam: no GIANTS files needed."
  echo "[install] Next: SERVER_MODE=server, start the server. The console shows a noVNC link for the one-time Steam login,"
  echo "[install] then Steam downloads the game (progress in the console) and the server starts by itself."
  exit 0
fi

if [ -n "${INSTALLER_URL:-}" ]; then
  # file name from the URL path (query string may contain tokens, never printed)
  url_path="${INSTALLER_URL%%\?*}"
  name="$(basename "$url_path")"
  [ -n "$name" ] && [ "$name" != "/" ] || name="fs25-installer.zip"
  host="$(printf '%s' "$INSTALLER_URL" | sed -E 's#^[a-zA-Z]+://([^/@]*@)?([^/:?]+).*#\2#')"
  if [ -f "installer/$name" ] || [ -f "installer/.extracted-$name" ]; then
    echo "[install] $name already downloaded, skipping"
  else
    echo "[install] downloading $name from $host ..."
    curl -fL --retry 3 --progress-bar -o "installer/$name.part" "$INSTALLER_URL" \
      || { echo "[install] ERROR: download failed"; rm -f "installer/$name.part"; exit 1; }
    mv "installer/$name.part" "installer/$name"
  fi
fi

# extract <archive> <dest>; keeps a marker so Reinstall does not extract twice
extract() {
  local a=$1 dest=$2 base marker
  base="$(basename "$a")"
  marker="$(dirname "$a")/.extracted-$base"
  [ -f "$marker" ] && { echo "[install] $base already extracted"; return 0; }
  echo "[install] extracting $base -> $dest/"
  mkdir -p "tmp/x" && rm -rf tmp/x/*
  if ! 7z x -y -bso0 -bsp0 -otmp/x "$a"; then
    echo "[install] ERROR: extraction of $base failed"; rm -rf tmp/x; return 1
  fi
  cp -a tmp/x/. "$dest/" && rm -rf tmp/x && touch "$marker"
}

for a in installer/*.img installer/*.iso installer/*.zip installer/*.7z; do
  extract "$a" installer || exit 1
done

# installer files may sit in a subfolder of the archive
if [ ! -f installer/Setup.exe ] && [ ! -f installer/FarmingSimulator2025.exe ]; then
  inner="$(find installer -mindepth 2 -maxdepth 4 \( -iname 'Setup.exe' -o -iname 'FarmingSimulator2025.exe' \) | head -n1)"
  if [ -n "$inner" ]; then
    echo "[install] moving installer files from $(dirname "$inner") to installer/"
    cp -a "$(dirname "$inner")"/. installer/
  fi
fi

# DLC: flatten every .exe from archives into dlc/
for a in dlc/*.img dlc/*.iso dlc/*.zip dlc/*.7z; do
  base="$(basename "$a")"
  [ -f "dlc/.extracted-$base" ] && continue
  mkdir -p tmp/dlc && rm -rf tmp/dlc/*
  echo "[install] extracting DLC $base"
  if 7z x -y -bso0 -bsp0 -otmp/dlc "$a"; then
    find tmp/dlc -type f -iname '*.exe' -exec mv -f {} dlc/ \;
    touch "dlc/.extracted-$base"
  else
    echo "[install] WARN: could not extract $base"
  fi
  rm -rf tmp/dlc
done

if [ -f installer/Setup.exe ] || [ -f installer/FarmingSimulator2025.exe ]; then
  echo "[install] installer is ready."
else
  echo "[install] No game installer yet. Upload the game (FarmingSimulator25_*_ESD.img/.zip or the extracted files)"
  echo "[install] to installer/ and DLC to dlc/ via SFTP or the file manager, then press Reinstall to extract them."
fi
for f in dlc/*.exe; do echo "[install] DLC: $(basename "$f")"; done
echo "[install] done. Next: SERVER_MODE=install, start the server, run Setup over noVNC."
