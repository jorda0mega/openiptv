"""Preview thumbnails for a film as a Roku BIF file (what Emby serves at
/Videos/{id}/index.bif): one 320-wide JPEG every 10 s.

Usage: python3 make_bif.py <film> <out.bif>. Needs ffmpeg.
"""
import glob
import os
import struct
import subprocess
import sys
import tempfile

film, out = sys.argv[1], sys.argv[2]
with tempfile.TemporaryDirectory() as frames:
    subprocess.run(["ffmpeg", "-v", "error", "-i", film, "-vf", "fps=1/10,scale=320:-2", "-q:v", "5",
                    os.path.join(frames, "%04d.jpg")], check=True)
    images = [open(path, "rb").read() for path in sorted(glob.glob(os.path.join(frames, "*.jpg")))]

# Header: magic, version 0, image count, timestamps in seconds (x1000 ms),
# reserved to 64 bytes; then (timestamp, offset) per image and an end entry.
header = b"\x89BIF\r\n\x1a\n" + struct.pack("<III", 0, len(images), 1000)
header += b"\0" * (64 - len(header))
offset = 64 + 8 * (len(images) + 1)
index = b""
for number, image in enumerate(images):
    index += struct.pack("<II", number * 10, offset)
    offset += len(image)
index += struct.pack("<II", 0xFFFFFFFF, offset)
with open(out, "wb") as f:
    f.write(header + index + b"".join(images))
