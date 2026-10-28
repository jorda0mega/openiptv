#!/usr/bin/env python3
"""make_sup.py OUT.sup: one PGS (Blu-ray picture) subtitle for a 1920x1080 film, on screen from 0.5 s to 59 s.

A white bar 600x60 px with a 4 px black edge at the bottom middle, drawn the way Blu-ray subtitles are:
an indexed picture with a YCbCr palette (white Y 235, black Y 16, the rest transparent).
"""
import struct
import sys

W, H = 1920, 1080
BAR_W, BAR_H, EDGE = 600, 60, 4
X, Y = (W - BAR_W) // 2, H - 160


def segment(kind, pts, data):
    return b"PG" + struct.pack(">IIBH", pts, pts, kind, len(data)) + data


def rle_line(pixels):
    out = bytearray()
    i = 0
    while i < len(pixels):
        color = pixels[i]
        run = 1
        while i + run < len(pixels) and pixels[i + run] == color and run < 16383:
            run += 1
        if color != 0 and run < 3:
            out += bytes([color]) * run
        elif color == 0:
            out += bytes([0, run]) if run < 64 else bytes([0, 0x40 | (run >> 8), run & 0xFF])
        else:
            out += bytes([0, 0x80 | run, color]) if run < 64 else bytes([0, 0xC0 | (run >> 8), run & 0xFF, color])
        i += run
    return bytes(out) + b"\x00\x00"


def picture():
    rows = []
    for y in range(BAR_H):
        row = []
        for x in range(BAR_W):
            edge = x < EDGE or y < EDGE or x >= BAR_W - EDGE or y >= BAR_H - EDGE
            row.append(2 if edge else 1)
        rows.append(rle_line(row))
    return b"".join(rows)


def display_set(pts, show):
    pcs = struct.pack(">HHBHBBBB", W, H, 0x10, 0 if show else 1, 0x80 if show else 0x00, 0, 0, 1 if show else 0)
    if show:
        pcs += struct.pack(">HBBHH", 0, 0, 0, X, Y)
    out = segment(0x16, pts, pcs)
    out += segment(0x17, pts, struct.pack(">BBHHHH", 1, 0, X, Y, BAR_W, BAR_H))
    if show:
        palette = struct.pack(">BB", 0, 0) + bytes([0, 16, 128, 128, 0, 1, 235, 128, 128, 255, 2, 16, 128, 128, 255])
        out += segment(0x14, pts, palette)
        data = picture()
        ods = struct.pack(">HBB", 0, 0, 0xC0) + (len(data) + 4).to_bytes(3, "big") + struct.pack(">HH", BAR_W, BAR_H) + data
        out += segment(0x15, pts, ods)
    out += segment(0x80, pts, b"")
    return out


with open(sys.argv[1], "wb") as f:
    f.write(display_set(45000, True) + display_set(59 * 90000, False))
