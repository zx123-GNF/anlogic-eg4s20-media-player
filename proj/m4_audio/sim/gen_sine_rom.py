#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_sine_rom.py -- generate rtl/m4_sine_rom.v (quarter wave sine table)

M4 milestone, AC208 / EG4S20BG256 + WM8960.

Why a quarter wave table
------------------------
The tone generator uses a 32 bit phase accumulator with a 10 bit table index
(1024 points per period).  A full wave table would need 1024 x 16 bit = 16 Kbit
(2 x BRAM9K).  A quarter wave table with the classic mirror trick needs only
256 x 16 bit = 4 Kbit (1 x BRAM9K):

    idx  = phase[31:22]        (10 bit, 0..1023)
    quad = idx[9:8]            (0..3)
    a    = idx[8] ? ~idx[7:0] : idx[7:0]      <- mirror inside the quadrant
    mag  = table[a]            (0 .. 16384)
    s    = quad[1] ? -mag : +mag              <- sign of the 2nd half

Sample values are +-16384, i.e. exactly half of full scale 32768, which is
-6.02 dBFS.  The table is centred (a+0.5) so that DC is exactly zero and the
peak is not clipped.

Usage
-----
    python sim/gen_sine_rom.py            # writes rtl/m4_sine_rom.v
    python sim/gen_sine_rom.py --check    # only verify the existing file
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "rtl", "m4_sine_rom.v")

DEPTH = 256
AMPL = 16384            # -6.02 dBFS


def table():
    return [int(round(AMPL * math.sin(math.pi / 2.0 * (a + 0.5) / DEPTH)))
            for a in range(DEPTH)]


def render(vals):
    L = []
    L.append("//=============================================================================")
    L.append("//  m4_sine_rom.v  --  1/4 wave sine table for the M4 1 kHz test tone")
    L.append("//")
    L.append("//  GENERATED FILE - do not edit, run:  python sim/gen_sine_rom.py")
    L.append("//")
    L.append("//  Contents : %d entries, 16 bit unsigned magnitude" % DEPTH)
    L.append("//             value[a] = round(%d * sin(pi/2 * (a+0.5)/%d))" % (AMPL, DEPTH))
    L.append("//  Range    : %d .. %d  (peak = -6.02 dBFS for a 16 bit sample)" % (vals[0], max(vals)))
    L.append("//  Ports    : synchronous read, 1 clock latency (infers one BRAM9K)")
    L.append("//=============================================================================")
    L.append("`timescale 1ns / 10ps")
    L.append("")
    L.append("module m4_sine_rom (")
    L.append("    input  wire        I_clk,")
    L.append("    input  wire [7:0]  I_addr,      // 0..255 = 0 .. 90 degrees")
    L.append("    output reg  [15:0] O_data       // 0 .. 16384, unsigned magnitude")
    L.append(");")
    L.append("")
    L.append("    reg [15:0] S_rom [0:%d];" % (DEPTH - 1))
    L.append("")
    L.append("    initial begin")
    for a in range(DEPTH):
        L.append("        S_rom[%3d] = 16'd%-5d;" % (a, vals[a]))
    L.append("    end")
    L.append("")
    L.append("    always @(posedge I_clk) begin")
    L.append("        O_data <= S_rom[I_addr];")
    L.append("    end")
    L.append("")
    L.append("endmodule")
    L.append("")
    return "\n".join(L)


def main():
    vals = table()
    txt = render(vals)
    if "--check" in sys.argv:
        with open(OUT, "r", encoding="utf-8") as f:
            cur = f.read()
        if cur == txt:
            print("OK   m4_sine_rom.v is up to date (%d entries)" % DEPTH)
            return 0
        print("FAIL m4_sine_rom.v differs from the generator")
        return 1
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(txt)
    print("wrote %s (%d entries, peak %d)" % (OUT, DEPTH, max(vals)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
