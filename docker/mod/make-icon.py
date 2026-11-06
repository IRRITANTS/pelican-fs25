# Writes icon_pelicanSave.dds: 256x256 uncompressed BGRA, green disk with a white "save" square.
# Run: python3 make-icon.py <out.dds>   (the result is committed, this script is only for regenerating it)
import struct, sys

W = H = 256
header = struct.pack(
    "<4sIIIIIII44xII4sIIIIIIIII4x",
    b"DDS ", 124, 0x1 | 0x2 | 0x4 | 0x1000 | 0x8, H, W, W * 4, 0, 1,
    32, 0x41, b"\0\0\0\0", 32, 0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000, 0x1000, 0, 0, 0,
)
px = bytearray()
for y in range(H):
    for x in range(W):
        dx, dy = x - 127.5, y - 127.5
        if dx * dx + dy * dy > 120 * 120:
            px += bytes((0, 0, 0, 0))
        elif 72 <= x <= 184 and 72 <= y <= 184 and not (96 <= x <= 160 and 72 <= y <= 112):
            px += bytes((255, 255, 255, 255))
        else:
            px += bytes((60, 150, 40, 255))
open(sys.argv[1], "wb").write(header + bytes(px))
