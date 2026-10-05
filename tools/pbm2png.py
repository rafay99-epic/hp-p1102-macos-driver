# Converts a (multi-page) PBM P4 stream to PNGs for eyeballing filter output.
# Usage: python3 tools/pbm2png.py in.pbm out-prefix [scale]
import sys, zlib, struct

def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)

data, prefix = open(sys.argv[1], "rb").read(), sys.argv[2]
scale = int(sys.argv[3]) if len(sys.argv) > 3 else 1
pos, page = 0, 0
while pos < len(data):
    tok = []
    while len(tok) < 3:
        while data[pos:pos+1].isspace(): pos += 1
        s = pos
        while not data[pos:pos+1].isspace(): pos += 1
        tok.append(data[s:pos])
    pos += 1
    w, h = int(tok[1]), int(tok[2]); bpl = (w + 7) // 8
    rows = [data[pos + y * bpl: pos + (y + 1) * bpl] for y in range(h)]
    pos += bpl * h; page += 1
    # Box-downsample to gray so a 600dpi page is viewable.
    ow, oh = w // scale, h // scale
    raw = bytearray()
    for oy in range(oh):
        raw.append(0)
        acc = [0] * ow
        for dy in range(scale):
            r = rows[oy * scale + dy]
            bits = int.from_bytes(r, "big")
            nb = len(r) * 8
            for ox in range(ow):
                seg = (bits >> (nb - (ox + 1) * scale)) & ((1 << scale) - 1)
                acc[ox] += bin(seg).count("1")
        raw.extend(255 - a * 255 // (scale * scale) for a in acc)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", ow, oh, 8, 0, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b"")
    open(f"{prefix}-{page}.png", "wb").write(png)
    print(f"page {page}: {w}x{h} -> {prefix}-{page}.png")
