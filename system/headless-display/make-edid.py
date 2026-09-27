#!/usr/bin/env python3
"""Write a 128-byte EDID 1.3 block for a fake 1920x1080@60 monitor ("Headless").

Single CEA-861 1080p60 detailed timing (148.5 MHz), so no extension block is
needed. Usage: make-edid.py OUT.bin
"""
import sys

def mfg_id(s):
    a, b, c = (ord(ch) - ord("A") + 1 for ch in s)
    v = (a << 10) | (b << 5) | c
    return bytes([v >> 8, v & 0xFF])

edid = bytearray()
edid += bytes([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])  # header
edid += mfg_id("LNX")
edid += bytes([0x01, 0x00])                    # product code
edid += bytes([0x00, 0x00, 0x00, 0x00])        # serial (none)
edid += bytes([0x01, 2026 - 1990])             # week, year
edid += bytes([0x01, 0x03])                    # EDID 1.3
edid += bytes([0x80, 53, 30, 0x78, 0x0E])      # digital, 53x30 cm, gamma 2.2, sRGB, RGB, preferred timing
edid += bytes([0xEE, 0x91, 0xA3, 0x54, 0x4C, 0x99, 0x26, 0x0F, 0x50, 0x54])  # sRGB chromaticity
edid += bytes([0x00, 0x00, 0x00])              # no established timings
edid += bytes([0x01, 0x01] * 8)                # no standard timings
# DTD 1: 1920x1080@60, 148.5 MHz, hblank 280 (88/44), vblank 45 (4/5), +h +v
edid += bytes([0x02, 0x3A, 0x80, 0x18, 0x71, 0x38, 0x2D, 0x40, 0x58, 0x2C,
               0x45, 0x00, 0x13, 0x2A, 0x21, 0x00, 0x00, 0x1E])
# Range limits: 56-76 Hz V, 30-83 kHz H, 170 MHz max pixel clock
edid += bytes([0x00, 0x00, 0x00, 0xFD, 0x00, 0x38, 0x4C, 0x1E, 0x53, 0x11,
               0x00, 0x0A, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20])
# Monitor name
name = b"Headless\n"
edid += bytes([0x00, 0x00, 0x00, 0xFC, 0x00]) + name + b" " * (13 - len(name))
# Dummy descriptor
edid += bytes([0x00, 0x00, 0x00, 0x10, 0x00]) + bytes(13)
edid += bytes([0x00])                          # no extension blocks
edid += bytes([(-sum(edid)) & 0xFF])           # checksum
assert len(edid) == 128 and sum(edid) % 256 == 0
open(sys.argv[1], "wb").write(edid)
