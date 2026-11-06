# Packs FS25_PelicanSave.zip with fixed timestamps, so the zip (and its hash the game compares with
# clients) only changes when the mod files change. Usage: python3 pack.py <out.zip>
import sys, zipfile

with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    for name in ("modDesc.xml", "PelicanSave.lua", "icon_pelicanSave.dds"):
        info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        with open(name, "rb") as f:
            z.writestr(info, f.read())
