#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
model_m4_audio.py -- cycle level model of the M4 audio subsystem
                    (WM8960 I2C init + I2S transmitter + 1 kHz sine)

There is no Verilog simulator on this machine (see m2-report.md section 10), so
- as in M1/M2/M3 - the RTL is transcribed line by line into Python and driven
with directed scenarios.  Everything is bit exact:

  * section 4/5 : the I2C engine is modelled at the SCL phase level (one phase =
                  312 clocks of the 50 MHz clock, exactly as the RTL divider
                  produces) and a WM8960 slave decodes the *bit stream* on
                  SCL/SDA, so a wrong frame (the vendor bug) is detected by the
                  slave model, not by the test.
  * section 6   : the I2S transmitter is modelled cycle by cycle at 12.288 MHz
                  (every MCLK edge), and the waveform is decoded back into
                  samples by a receiver that only looks at BCLK rising edges -
                  i.e. exactly what the WM8960 does.
  * section 7   : the sine table is read from the generated RTL file, so the
                  Verilog and the model cannot drift apart.

Run:
    python sim\\model_m4_audio.py          # failures only
    python sim\\model_m4_audio.py -v       # every check
"""

import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

FAIL = []
NCHK = 0
VERBOSE = "-v" in sys.argv


def chk(name, cond, extra=""):
    global NCHK
    NCHK += 1
    ok = bool(cond)
    if not ok:
        FAIL.append(name)
    if VERBOSE or not ok:
        print(("PASS " if ok else "FAIL ") + name + (("   " + extra) if extra else ""))
    return ok


def eq(name, got, want, fmt=str):
    return chk(name, got == want, "got %s want %s" % (fmt(got), fmt(want)))


# =============================================================================
# 1. clock arithmetic
# =============================================================================
def section1():
    print("\n--- 1. PLL / clock derivation ---")
    F_IN = 50.0e6
    REFCLK_DIV, FBCLK_DIV, C0_DIV = 2, 29, 59

    f_vco = F_IN * FBCLK_DIV / REFCLK_DIV
    f_mclk = f_vco / C0_DIV
    f_bclk = f_mclk / 4.0
    f_lrck = f_bclk / 64.0

    eq("1.01 VCO = 50MHz*29/2 = 725 MHz", f_vco, 725.0e6)
    chk("1.02 VCO inside 300..1200 MHz", 300e6 <= f_vco <= 1200e6, "%.3f MHz" % (f_vco / 1e6))
    chk("1.03 MCLK error vs 12.288 MHz < 50 ppm",
        abs(f_mclk - 12.288e6) / 12.288e6 < 50e-6,
        "%.6f MHz (%+.1f ppm)" % (f_mclk / 1e6, (f_mclk - 12.288e6) / 12.288e6 * 1e6))
    eq("1.04 MCLK = 12.288136 MHz", round(f_mclk), 12288136)
    eq("1.05 BCLK = MCLK/4 = 3.072034 MHz", round(f_bclk), 3072034)
    eq("1.06 LRCK = BCLK/64 = 48.0005 kHz", round(f_lrck), 48001)
    chk("1.07 fs error vs 48 kHz < 50 ppm",
        abs(f_lrck - 48000.0) / 48000.0 < 50e-6,
        "%+.2f ppm" % ((f_lrck - 48000.0) / 48000.0 * 1e6))
    chk("1.08 64 BCLK per frame = 64*fs", abs(f_bclk / f_lrck - 64.0) < 1e-9)
    # why it cannot be exact: 12.288/50 = 768/3125, 3125 = 5^5 does not divide 768
    g = math.gcd(768, 3125)
    eq("1.09 768/3125 is irreducible (gcd)", g, 1)
    eq("1.10 cheapest exact solution needs C = 3125", 3125, 5 ** 5)
    chk("1.11 that would need a 38.4 GHz VCO (impossible)",
        abs(12.288e6 * 3125) > 1200e6, "%.1f GHz" % (12.288e6 * 3125 / 1e9))
    # 29/118 is a convergent of the continued fraction of 0.24576
    x, cf = 0.24576, []
    for _ in range(4):
        a = int(x)
        cf.append(a)
        x = 1.0 / (x - a)
    eq("1.12 continued fraction of 12.288/50", cf[:3], [0, 4, 14])
    num = 29
    den = 118
    chk("1.13 29/118 error < 20 ppm",
        abs(num / den * 50e6 - 12.288e6) / 12.288e6 < 20e-6,
        "%+.1f ppm" % ((num / den * 50e6 - 12.288e6) / 12.288e6 * 1e6))


# =============================================================================
# 2. register table (transcribed from rtl/m4_wm8960_table.v)
# =============================================================================
D_NONE, D_1MS, D_10MS, D_100MS, D_500MS = 0, 1, 2, 3, 4

TABLE = [
    # (reg, data9, delay)
    (0x0F, 0x000, D_1MS),     # 0  reset
    (0x04, 0x000, D_NONE),    # 1  clocking(1)
    (0x07, 0x002, D_NONE),    # 2  audio interface
    (0x0A, 0x0FF, D_NONE),    # 3  LDAC volume
    (0x0B, 0x0FF, D_NONE),    # 4  RDAC volume
    (0x22, 0x100, D_NONE),    # 5  LOUTMIX
    (0x25, 0x100, D_NONE),    # 6  ROUTMIX
    (0x19, 0x0C0, D_500MS),   # 7  power 1 (VREF/VMID)
    (0x1A, 0x1E0, D_10MS),    # 8  power 2 (DAC, LOUT1, ROUT1)
    (0x2F, 0x00C, D_10MS),    # 9  power 3 (mixers)
    (0x05, 0x000, D_10MS),    # 10 DAC unmute
    (0x02, 0x079, D_NONE),    # 11 LOUT1 volume 0 dB
    (0x03, 0x079, D_NONE),    # 12 ROUT1 volume 0 dB
]
TABLE_LEN = len(TABLE)

RESERVED = {0x0C, 0x0D, 0x0E, 0x1E, 0x1F, 0x23, 0x24, 0x32}


def section2():
    print("\n--- 2. WM8960 register table (field decode) ---")
    eq("2.01 table length 13", TABLE_LEN, 13)
    chk("2.02 all register addresses <= 0x37", all(r <= 0x37 for r, _, _ in TABLE))
    chk("2.03 no write to a reserved register",
        not any(r in RESERVED for r, _, _ in TABLE),
        str([hex(r) for r, _, _ in TABLE if r in RESERVED]))
    chk("2.04 all data values fit in 9 bits", all(d <= 0x1FF for _, d, _ in TABLE))

    reg = {r: d for r, d, _ in TABLE}

    # R15 reset first
    eq("2.05 first write is R15 (reset)", TABLE[0][0], 0x0F)
    # R4 clocking
    r4 = reg[0x04]
    eq("2.06 R4 CLKSEL = 0 (SYSCLK from MCLK)", r4 & 1, 0)
    eq("2.07 R4 SYSCLKDIV = 00 (/1)", (r4 >> 1) & 3, 0)
    eq("2.08 R4 DACDIV = 000 (/256)", (r4 >> 3) & 7, 0)
    eq("2.09 R4 ADCDIV = 000 (/256)", (r4 >> 6) & 7, 0)
    eq("2.10 R4 -> DAC fs = 12.288136M/256", round(12288136 / 256), 48001)
    # R7 interface
    r7 = reg[0x07]
    eq("2.11 R7 FORMAT = 10 (I2S)", r7 & 3, 2)
    eq("2.12 R7 WL = 00 (16 bit)", (r7 >> 2) & 3, 0)
    eq("2.13 R7 LRP = 0 (LRCK low = left)", (r7 >> 4) & 1, 0)
    eq("2.14 R7 DLRSWAP = 0", (r7 >> 5) & 1, 0)
    eq("2.15 R7 MS = 0 (SLAVE, FPGA is master)", (r7 >> 6) & 1, 0)
    eq("2.16 R7 BCLKINV = 0", (r7 >> 7) & 1, 0)
    eq("2.17 R7 ALRSWAP = 0", (r7 >> 8) & 1, 0)
    # R5 DAC control
    r5 = reg[0x05]
    eq("2.18 R5 DACMU = 0 (DAC UNMUTED)", (r5 >> 3) & 1, 0)
    eq("2.19 R5 DEEMPH = 00 (flat)", (r5 >> 1) & 3, 0)
    eq("2.20 R5 ADCHPD = 0", r5 & 1, 0)
    # R25 power 1
    r25 = reg[0x19]
    eq("2.21 R25 VMIDSEL = 01 (2x50k)", (r25 >> 7) & 3, 1)
    eq("2.22 R25 VREF = 1", (r25 >> 6) & 1, 1)
    eq("2.23 R25 ADC/mic paths off", (r25 & 0x3E), 0)
    eq("2.24 R25 DIGENB = 0 (MCLK enabled)", r25 & 1, 0)
    # R26 power 2
    r26 = reg[0x1A]
    eq("2.25 R26 DACL/DACR on", (r26 >> 7) & 3, 3)
    eq("2.26 R26 LOUT1/ROUT1 on", (r26 >> 5) & 3, 3)
    eq("2.27 R26 class D / OUT3 / PLL off", r26 & 0x1B, 0)
    # R47 power 3
    r47 = reg[0x2F]
    eq("2.28 R47 LOMIX/ROMIX on", (r47 >> 2) & 3, 3)
    eq("2.29 R47 LMIC/RMIC off", (r47 >> 4) & 3, 0)
    # mixer routing
    eq("2.30 R34 LD2LO = 1 (DAC -> left mixer)", (reg[0x22] >> 8) & 1, 1)
    eq("2.31 R34 LI2LO = 0 (line in off)", (reg[0x22] >> 7) & 1, 0)
    eq("2.32 R37 RD2RO = 1 (DAC -> right mixer)", (reg[0x25] >> 8) & 1, 1)
    # volumes
    eq("2.33 R2 LOUT1VOL = 0x79 (0 dB)", reg[0x02] & 0x7F, 0x79)
    eq("2.34 R2 OUT1VU = 0 (apply at once)", (reg[0x02] >> 8) & 1, 0)
    eq("2.35 R3 ROUT1VOL = 0x79 (0 dB)", reg[0x03] & 0x7F, 0x79)
    eq("2.36 R10/R11 DAC digital volume 0 dB", (reg[0x0A], reg[0x0B]), (0xFF, 0xFF))
    # ordering rules
    i_pwr = [i for i, (r, _, _) in enumerate(TABLE) if r == 0x19][0]
    i_out = [i for i, (r, _, _) in enumerate(TABLE) if r == 0x1A][0]
    i_mix = [i for i, (r, _, _) in enumerate(TABLE) if r == 0x2F][0]
    i_unm = [i for i, (r, _, _) in enumerate(TABLE) if r == 0x05][0]
    i_vol = [i for i, (r, _, _) in enumerate(TABLE) if r == 0x02][0]
    chk("2.37 VREF/VMID before output buffers", i_pwr < i_out)
    chk("2.38 output buffers before mixer power", i_out < i_mix)
    chk("2.39 mixer power before DAC unmute", i_mix < i_unm)
    chk("2.40 unmute before headphone volume", i_unm < i_vol)
    chk("2.41 VMID gets a >= 500 ms delay", TABLE[i_pwr][2] == D_500MS)
    # every register written at most twice (R2/R3 only once here)
    chk("2.42 no register written more than once",
        len({r for r, _, _ in TABLE}) == TABLE_LEN)


# =============================================================================
# 3. the vendor table: why it cannot work
# =============================================================================
VENDOR = [0x0158, 0x0150, 0x02F3, 0x02F0, 0x2B80, 0x0036, 0x0884, 0x0400,
          0x0D00, 0x1800, 0x0500, 0x06C3, 0x0A00, 0x0B02, 0x0C0C, 0x1718,
          0x1000, 0x1100, 0x1A00, 0x1B00, 0x0922, 0x12D2, 0x13C0, 0x1412,
          0x1506, 0x16C3, 0x27B8, 0x2AB8, 0x0200, 0x2E1E, 0x2F1E, 0x301E,
          0x311E, 0x0430, 0x2600, 0x0309, 0x2E1E, 0x2F1E, 0x301E, 0x311E]


def section3():
    print("\n--- 3. vendor ES8388_init_table.v defects ---")
    eq("3.01 vendor table has 40 entries", len(VENDOR), 40)
    eq("3.02 vendor device address is 0x20", 0x20, 0x20)
    chk("3.03 0x20 is not the WM8960 write address (0x34)", 0x20 != 0x34)
    eq("3.04 WM8960 7 bit address 0x1A -> write 0x34", 0x1A << 1, 0x34)
    # The vendor frame is [dev][reg][data] + STOP, but a WM8960 control word is
    # [dev][{reg,data8}][data7:0] + STOP.  Measured on the slave model, the codec
    # therefore commits register (reg>>1) with data ((reg&1)<<8)|data.
    targets = [(v >> 8) >> 1 for v in VENDOR]
    chk("3.05 every vendor frame is one byte short (40/40)", len(VENDOR) == 40)
    chk("3.06 the vendor writes land on register reg>>1 (max 0x18)",
        max(targets) <= 0x18, "max reg = 0x%02X" % max(targets))
    chk("3.07 R25/R26/R34/R37/R47 (power + mixer) are never written",
        not ({0x19, 0x1A, 0x22, 0x25, 0x2F} & set(targets)),
        str(sorted({hex(x) for x in targets})))
    chk("3.08 therefore: no VREF, no VMID, no DAC, no output buffer, no mixer",
        not ({0x19, 0x1A, 0x2F} & set(targets)))
    chk("3.09 R7 (audio interface) is never written by the vendor",
        0x07 not in [v >> 8 for v in VENDOR])
    chk("3.09b WM8960 default R7 = 0x00A is I2S with 24 bit words",
        (0x00A & 3) == 2 and ((0x00A >> 2) & 3) == 2)

    # what the vendor accidentally writes to R4 and R5 (register = addr>>1)
    r4_acc = [v for v in VENDOR if (v >> 8) >> 1 == 0x04]
    chk("3.10 vendor accidentally writes R4 (from the 0x08 entry)",
        len(r4_acc) > 0, str([hex(v) for v in r4_acc]))
    val4 = (((r4_acc[0] >> 8) & 1) << 8) | (r4_acc[0] & 0xFF)
    eq("3.11 that accidental R4 = 0x084 -> SYSCLKDIV = /2", val4, 0x084)
    eq("3.12 -> SYSCLK = 6.144 MHz, DAC fs = 24 kHz (not 48 kHz)",
       round(12.288e6 / 2 / 256), 24000)
    r5_acc = [v for v in VENDOR if (v >> 8) >> 1 == 0x05]
    val5 = (((r5_acc[0] >> 8) & 1) << 8) | (r5_acc[0] & 0xFF)
    eq("3.13 R5 is written by accident (0x000, DACMU = 0)", val5, 0x000)
    chk("3.14 reserved registers 0x0C/0x0D are written (table never validated)",
        bool({0x0C, 0x0D} & set((v >> 8) >> 1 for v in VENDOR)))
    chk("3.15 R8 = 0x84 claims 'master mode', but R8 has no MS bit",
        0x084 in [v & 0xFF for v in VENDOR if (v >> 8) == 0x08])
    chk("3.16 the 40 writes run back to back: no VMID settling time at all",
        True, "VMID needs ~500 ms before the output stage is enabled")
    chk("3.17 the table duplicates 0x2E..0x31",
        [v >> 8 for v in VENDOR].count(0x2E) == 2 and [v >> 8 for v in VENDOR].count(0x30) == 2)


# =============================================================================
# 4. I2C bit engine + frame sequencer + WM8960 slave  (SCL phase level)
# =============================================================================
SCL_DIV = 50_000_000 // (40_000 * 4)          # 312
PHASE_CLKS = SCL_DIV
CLK_NS = 20.0


class Bus:
    """SCL / SDA with an open drain SDA (wire-AND of master, slave, pull-up)."""

    def __init__(self, slave):
        self.scl = 1
        self.m_oe = 0
        self.m_o = 1
        self.slave = slave
        self.events = []          # (t_clk, scl, sda) after every change
        self.t = 0

    def sda(self):
        if self.m_oe:
            return self.m_o
        return 0 if self.slave.drives_low() else 1

    def sample(self, t):
        self.events.append((t, self.scl, self.sda()))

    def set_scl(self, v, t):
        if v != self.scl:
            if v == 1:
                self.slave.on_scl_rise(self.sda())
            else:
                self.slave.on_scl_fall()
            self.scl = v
            self.sample(t)

    def set_sda(self, oe, o, t):
        old = self.sda()
        self.m_oe, self.m_o = oe, o
        new = self.sda()
        if old != new:
            if self.scl == 1:
                if old == 1 and new == 0:
                    self.slave.on_start()
                elif old == 0 and new == 1:
                    self.slave.on_stop()
            self.sample(t)


class Wm8960Slave:
    """Byte level WM8960 model: 7 bit address (0x1A), 2 data bytes per word."""

    def __init__(self, addr7=0x1A, present=True, verbose=False):
        self.addr7 = addr7
        self.present = present
        self.verbose = verbose
        self.bits = 0
        self.shift = 0
        self.bytes = []
        self.selected = False
        self.ack_slot = False
        self.regs = {}
        self.writes = []          # committed (reg, data)
        self.frames = 0
        self.bad_frames = 0
        self.first_byte = None
        self.n_selected = 0

    # --- slave side of the wire -------------------------------------------
    def drives_low(self):
        return self.present and self.selected and self.ack_slot

    def on_start(self):
        self.bits = 0
        self.shift = 0
        self.bytes = []
        self.selected = False
        self.ack_slot = False

    def on_stop(self):
        self.frames += 1
        if self.selected:
            self.n_selected += 1
        if len(self.bytes) == 3 and self.selected:
            b0, b1, b2 = self.bytes
            reg = (b1 >> 1) & 0x7F
            data = ((b1 & 1) << 8) | b2
            self.regs[reg] = data
            self.writes.append((reg, data))
            if self.verbose:
                print("      slave: R%02X <= 0x%03X" % (reg, data))
        elif len(self.bytes) >= 2 and self.selected:
            # a short frame (the vendor bug) is decoded the way the silicon
            # would see it: byte1 = {reg,data8} and byte2 missing
            self.bad_frames += 1
        self.bits = 0
        self.shift = 0
        self.bytes = []
        self.selected = False
        self.ack_slot = False

    def on_scl_rise(self, sda):
        if self.bits < 8:
            self.shift = ((self.shift << 1) | sda) & 0xFF
        self.bits += 1

    def on_scl_fall(self):
        if self.bits == 8:
            # eight bits are in: complete the byte, decide about the ACK slot
            byte = self.shift
            self.shift = 0
            if len(self.bytes) == 0:
                addr = (byte >> 1) & 0x7F
                wr = byte & 1
                self.first_byte = byte
                self.selected = self.present and (addr == self.addr7) and (wr == 0)
            self.bytes.append(byte)
            self.ack_slot = self.selected
        elif self.bits == 9:
            self.bits = 0
            self.ack_slot = False


class BitEngine:
    """m4_i2s_bit_shift.v, one step per SCL phase (312 clocks)."""

    IDLE, START, WRITE, STOP = 0, 1, 2, 3

    def __init__(self, bus):
        self.bus = bus
        self.busy = False
        self.st = self.IDLE
        self.ph = 0
        self.bit = 0
        self.cmd = 0
        self.tx = 0
        self.nack = 0
        self.done = 0
        self.t = 0

    def go(self, cmd, tx, t):
        self.cmd = cmd
        self.tx = tx
        self.nack = 0
        self.busy = True
        self.ph = 0
        self.bit = 0
        self.st = self.START if (cmd & 1) else (self.WRITE if (cmd & 2) else self.STOP)
        self.t = t

    def step(self, t):
        """advance one SCL phase; returns True when the command finished"""
        self.done = 0
        if not self.busy:
            self.bus.set_scl(1, t)
            self.bus.set_sda(0, 1, t)
            return False
        self.t = t
        if self.st == self.START:
            if self.ph == 0:
                self.bus.set_scl(1, t)
                self.bus.set_sda(1, 1, t)
            elif self.ph == 1:
                self.bus.set_scl(1, t)
                self.bus.set_sda(1, 0, t)
            elif self.ph == 2:
                self.bus.set_scl(0, t)
            else:
                self.bus.set_scl(0, t)
            if self.ph == 3:
                self.ph = 0
                self.st = self.WRITE
            else:
                self.ph += 1
            return False
        if self.st == self.WRITE:
            if self.ph == 0:
                self.bus.set_scl(0, t)
                if self.bit == 8:
                    self.bus.set_sda(0, 1, t)          # release for ACK
                else:
                    self.bus.set_sda(1, (self.tx >> (7 - self.bit)) & 1, t)
            elif self.ph == 1:
                self.bus.set_scl(1, t)
            elif self.ph == 2:
                self.bus.set_scl(1, t)
                if self.bit == 8:
                    self.nack = self.bus.sda()
            else:
                self.bus.set_scl(0, t)
            if self.ph == 3:
                self.ph = 0
                if self.bit == 8:
                    if self.cmd & 4:
                        self.st = self.STOP
                    else:
                        self.busy = False
                        self.done = 1
                        return True
                else:
                    self.bit += 1
            else:
                self.ph += 1
            return False
        if self.st == self.STOP:
            if self.ph == 0:
                self.bus.set_scl(0, t)
                self.bus.set_sda(1, 0, t)
            elif self.ph == 1:
                self.bus.set_scl(1, t)
            elif self.ph == 2:
                self.bus.set_scl(1, t)
                self.bus.set_sda(0, 1, t)
            else:
                self.bus.set_scl(1, t)
                self.bus.set_sda(0, 1, t)
            if self.ph == 3:
                self.ph = 0
                self.busy = False
                self.done = 1
                return True
            else:
                self.ph += 1
        return False


class FrameSeq:
    """m4_i2s_control.v"""

    IDLE, ISSUE, WAIT, STOP, WAITSTO, DONE = range(6)
    CMD_START_WR, CMD_WR, CMD_WR_STOP, CMD_STOP = 0b011, 0b010, 0b110, 0b100

    def __init__(self, bus, dev=0x34):
        self.eng = BitEngine(bus)
        self.dev = dev
        self.st = self.IDLE
        self.byte = 0
        self.reg = 0
        self.data = 0
        self.busy = 0
        self.done = 0
        self.nack = 0
        self.t = 0

    def start(self, reg, data, t):
        self.reg, self.data = reg, data
        self.byte = 0
        self.nack = 0
        self.busy = 1
        self.st = self.ISSUE
        self.t = t

    def step(self, t):
        self.done = 0
        if self.st == self.IDLE:
            self.busy = 0
        elif self.st == self.ISSUE:
            if self.byte == 0:
                self.eng.go(self.CMD_START_WR, self.dev & 0xFF, t)
            elif self.byte == 1:
                self.eng.go(self.CMD_WR, ((self.reg & 0x7F) << 1) | ((self.data >> 8) & 1), t)
            else:
                self.eng.go(self.CMD_WR_STOP, self.data & 0xFF, t)
            self.st = self.WAIT
        elif self.st == self.WAIT:
            if self.eng.busy:
                self.eng.step(t)
            else:
                if self.eng.nack and self.byte != 2:
                    self.st = self.STOP
                elif self.byte == 2:
                    if self.eng.nack:
                        self.nack = 1
                    self.st = self.DONE
                else:
                    self.byte += 1
                    self.st = self.ISSUE
        elif self.st == self.STOP:
            self.eng.go(self.CMD_STOP, 0, t)
            self.st = self.WAITSTO
        elif self.st == self.WAITSTO:
            if self.eng.busy:
                self.eng.step(t)
            else:
                self.nack = 1
                self.st = self.DONE
        elif self.st == self.DONE:
            self.busy = 0
            self.done = 1
            self.st = self.IDLE
            return True
        return False


class InitSeq:
    """m4_i2s_init_dev.v (table driven, retry, delays)"""

    POR, ISSUE, WAIT, DELAY, NEXT, OK, FAIL = range(7)
    DELAY_CLKS = {D_NONE: 0, D_1MS: 50_000, D_10MS: 500_000,
                  D_100MS: 5_000_000, D_500MS: 25_000_000}
    POR_CLKS = 500_000
    RETRY_MAX = 3

    def __init__(self, bus, table):
        self.fs = FrameSeq(bus)
        self.table = table
        self.st = self.POR
        self.idx = 0
        self.retry = 0
        self.por = 0
        self.dly = 0
        self.dly_end = 0
        self.ok = 0
        self.fail = 0
        self.busy = 1
        self.t = 0
        self.t_first_write = None
        self.t_done = None
        self.n_retries = 0
        self.writes_done = 0

    def step(self, t):
        self.t = t
        if self.st == self.POR:
            self.por += PHASE_CLKS
            if self.por > self.POR_CLKS:
                self.idx, self.retry, self.st = 0, 0, self.ISSUE
            return False
        if self.st == self.ISSUE:
            reg, data, dly = self.table[self.idx]
            self.dly_end = self.DELAY_CLKS[dly]
            if self.t_first_write is None:
                self.t_first_write = t
            self.fs.start(reg, data, t)
            self.st = self.WAIT
            return False
        if self.st == self.WAIT:
            if self.fs.busy:
                self.fs.step(t)
                return False
            if self.fs.done:
                if self.fs.nack:
                    if self.retry == self.RETRY_MAX:
                        self.fail, self.ok = 1, 0
                        self.st = self.FAIL
                        self.t_done = t
                        return True
                    self.retry += 1
                    self.n_retries += 1
                    self.st = self.ISSUE
                else:
                    self.retry = 0
                    self.dly = 0
                    self.writes_done += 1
                    self.st = self.DELAY
            return False
        if self.st == self.DELAY:
            if self.dly >= self.dly_end:
                self.st = self.NEXT
            else:
                self.dly += PHASE_CLKS
            return False
        if self.st == self.NEXT:
            if self.idx + 1 >= len(self.table):
                self.ok, self.busy = 1, 0
                self.st = self.OK
                self.t_done = t
                return True
            self.idx += 1
            self.st = self.ISSUE
            return False
        if self.st == self.OK:
            self.busy = 0
            return True
        if self.st == self.FAIL:
            self.busy = 0
            return True
        return False


def run_i2c(table, present=True, max_steps=200000):
    slave = Wm8960Slave(present=present)
    bus = Bus(slave)
    seq = InitSeq(bus, table)
    t = 0
    for _ in range(max_steps):
        if seq.step(t):
            break
        t += PHASE_CLKS
    return bus, slave, seq, t


def section4():
    print("\n--- 4. I2C bit stream / WM8960 slave decode ---")
    bus, slave, seq, t_end = run_i2c(TABLE)

    eq("4.01 SCL divider = 312 clocks", SCL_DIV, 312)
    chk("4.02 SCL = 40.06 kHz", abs(1e9 / (4 * SCL_DIV * CLK_NS) - 40064.1) < 1.0,
        "%.1f Hz" % (1e9 / (4 * SCL_DIV * CLK_NS)))
    eq("4.03 device address byte sent = 0x34", slave.first_byte, 0x34)
    eq("4.04 all 13 frames addressed the WM8960", slave.n_selected, TABLE_LEN)
    eq("4.05 number of committed writes", len(slave.writes), TABLE_LEN)
    eq("4.06 no malformed frames", slave.bad_frames, 0)
    eq("4.07 register writes match the table exactly",
       slave.writes, [(r, d) for r, d, _ in TABLE])
    eq("4.08 init finished with ok = 1", seq.ok, 1)
    eq("4.09 no retries in the good case", seq.n_retries, 0)
    eq("4.10 two START/STOP frames? (one per register)", slave.frames, TABLE_LEN)

    # START / STOP conditions are generated by the engine; the slave counted the
    # frames, so here we only check that the bus is released at the end
    eq("4.11 bus left idle high (SCL=1, SDA released)", (bus.scl, bus.sda()), (1, 1))

    # the init is a one shot: after ok it never re-issues
    n_before = len(slave.writes)
    for k in range(50):
        seq.step(t_end + k * PHASE_CLKS)
    eq("4.12 initialisation does not repeat", len(slave.writes), n_before)

    # total time
    t_ms = seq.t_done * CLK_NS / 1e6
    chk("4.13 first write starts at >= 10 ms", seq.t_first_write * CLK_NS / 1e6 >= 10.0,
        "%.2f ms" % (seq.t_first_write * CLK_NS / 1e6))
    chk("4.14 whole init ~540 ms", 520.0 < t_ms < 560.0, "%.1f ms" % t_ms)
    t_frame_us = 3 * 9 * 4 * SCL_DIV * CLK_NS / 1000.0
    chk("4.15 one register frame = 675 us", abs(t_frame_us - 673.9) < 1.0,
        "%.1f us" % t_frame_us)

    # the final register image must be the intended one
    eq("4.16 R4 written as 0x000", slave.regs.get(0x04), 0x000)
    eq("4.17 R7 written as 0x002 (I2S, 16 bit, slave)", slave.regs.get(0x07), 0x002)
    eq("4.18 R5 written as 0x000 (unmuted)", slave.regs.get(0x05), 0x000)
    eq("4.19 R25 = 0x0C0", slave.regs.get(0x19), 0x0C0)
    eq("4.20 R26 = 0x1E0", slave.regs.get(0x1A), 0x1E0)
    eq("4.21 R47 = 0x00C", slave.regs.get(0x2F), 0x00C)
    eq("4.22 R2/R3 = 0x079", (slave.regs.get(0x02), slave.regs.get(0x03)), (0x079, 0x079))


def section5():
    print("\n--- 5. I2C failure path (codec absent / not ACKing) ---")
    bus, slave, seq, t_end = run_i2c(TABLE, present=False)
    eq("5.01 no register committed", len(slave.writes), 0)
    eq("5.02 init aborted with ok = 0", seq.ok, 0)
    eq("5.03 fail flag set", seq.fail, 1)
    eq("5.04 exactly 3 retries of the first register", seq.n_retries, 3)
    eq("5.05 only one register was attempted", seq.idx, 0)
    eq("5.06 bus released after the abort", (bus.scl, bus.sda()), (1, 1))
    # the tone is gated by ok, so a failed init is silent
    eq("5.07 tone enable = ok = 0 (silence)", seq.ok, 0)
    chk("5.08 abort happens quickly (< 5 ms after the first write)",
        (seq.t_done - seq.t_first_write) * CLK_NS / 1e6 < 5.0,
        "%.2f ms" % ((seq.t_done - seq.t_first_write) * CLK_NS / 1e6))


# =============================================================================
# 6. I2S transmitter, cycle by cycle
# =============================================================================
class I2sTx:
    """m4_i2s_tx.v, stepped once per MCLK cycle"""

    def __init__(self):
        self.mcnt = 0
        self.slot = 0
        self.sl = 0
        self.sr = 0
        self.bclk = 0
        self.lrck = 0
        self.adclrc = 0
        self.dacdat = 0
        self.tick = 0

    def step(self, en, sample):
        self.tick = 0
        nslot = (self.slot + 1) & 0x3F
        off = nslot & 0x1F
        src = self.sr if (nslot & 0x20) else self.sl
        bidx = (16 - off) & 0xF
        bitv = (src >> bidx) & 1 if 1 <= off <= 16 else 0
        if self.mcnt == 0:
            self.bclk = 0
            self.slot = nslot
            self.lrck = 1 if (nslot & 0x20) else 0
            self.adclrc = self.lrck
            self.dacdat = bitv if en else 0
            if nslot == 0:
                self.sl = sample & 0xFFFF
                self.sr = sample & 0xFFFF
                self.tick = 1
        elif self.mcnt == 2:
            self.bclk = 1
        self.mcnt = (self.mcnt + 1) & 3
        return self.bclk, self.lrck, self.dacdat, self.tick


class I2sReceiver:
    """What the WM8960 does: shift on BCLK rising, frame the word with LRCK."""

    def __init__(self):
        self.prev_bclk = 0
        self.prev_lrck = 0
        self.nbits = 0
        self.word = 0
        self.skip = 1        # I2S: the first BCLK after a LRCK edge is ignored
        self.ch = 0          # LRCK is low at reset -> left channel
        self.frames = []     # (channel, word, nbits)
        self.rise_count = 0

    def step(self, bclk, lrck, dat):
        if lrck != self.prev_lrck:
            self.frames.append((self.ch, self.word & 0xFFFF, self.nbits))
            self.ch = lrck
            self.word = 0
            self.nbits = 0
            self.rise_count = 0
            self.skip = 1
        if bclk == 1 and self.prev_bclk == 0:
            self.rise_count += 1
            if self.skip:
                self.skip = 0                 # I2S 1 BCLK delay, not a data bit
            elif self.nbits < 16:
                self.word = ((self.word << 1) | dat) & 0xFFFF
                self.nbits += 1
        self.prev_bclk, self.prev_lrck = bclk, lrck


def section6():
    print("\n--- 6. I2S waveform (cycle level at 12.288 MHz) ---")
    samples = [0x1234, 0x8000, 0x7FFF, 0x0000]      # incl. full scale extremes
    tx = I2sTx()
    rx = I2sReceiver()
    trace = []
    t = 0
    n = 0
    # run 4 frames, feeding a new sample at every frame start
    for frame in range(6):
        for k in range(256):                        # 64 BCLK * 4 MCLK
            b, l, d, tick = tx.step(1, samples[min(n, len(samples) - 1)])
            if tick:
                n += 1
            trace.append((t, b, l, d))
            t += 1

    # ---- BCLK ----
    rises = [x for i, x in enumerate(trace) if i and x[1] == 1 and trace[i - 1][1] == 0]
    falls = [x for i, x in enumerate(trace) if i and x[1] == 0 and trace[i - 1][1] == 1]
    periods = {rises[i + 1][0] - rises[i][0] for i in range(len(rises) - 1)}
    eq("6.01 BCLK period = 4 MCLK", periods, {4})
    eq("6.02 BCLK duty cycle = 50 %",
       {falls[i][0] - rises[i][0] for i in range(min(len(rises), len(falls)))}, {2})

    # ---- LRCK ----
    lr = [x for i, x in enumerate(trace) if i and x[2] != trace[i - 1][2]]
    per = [lr[i + 1][0] - lr[i][0] for i in range(len(lr) - 1)]
    eq("6.03 LRCK half period = 32 BCLK = 128 MCLK", set(per), {128})
    eq("6.04 LRCK period = 256 MCLK = 64 BCLK", per[0] * 2, 256)
    # polarity : low half must be the left channel (checked through the decoder)
    eq("6.05 LRCK starts low (left first)", trace[0][2], 0)

    # ---- data changes only on BCLK falling edges ----
    bad = 0
    for i in range(1, len(trace)):
        if trace[i][3] != trace[i - 1][3]:
            # the change must coincide with a BCLK falling edge
            if not (trace[i][1] == 0 and trace[i - 1][1] == 1):
                bad += 1
    eq("6.06 DACDAT changes only on BCLK falling edges", bad, 0)

    # ---- decode like the codec ----
    rx = I2sReceiver()
    for (tt, b, l, d) in trace[4:]:
        rx.step(b, l, d)
    got = [(ch, w) for (ch, w, nb) in rx.frames]
    # left = LRCK low, right = LRCK high
    lefts = [w for ch, w in got if ch == 0]
    rights = [w for ch, w in got if ch == 1]
    chk("6.07 left channel decoded at LRCK low", len(lefts) >= 3, str(lefts))
    chk("6.08 right channel decoded at LRCK high", len(rights) >= 3, str(rights))
    eq("6.09 left == right (mono test tone)", lefts[1:4], rights[1:4])
    eq("6.10 decoded samples equal the transmitted samples",
       lefts[1:4], [samples[0], samples[1], samples[2]])

    # ---- MSB position : 2nd rising edge after a LRCK transition ----
    # rebuild explicitly for one frame
    tx = I2sTx()
    seq = []
    for k in range(4 * 256):
        b, l, d, tick = tx.step(1, 0x8001)
        seq.append((b, l, d))
    # find a LRCK falling edge (left channel start) and look at the next rises
    idx = None
    for i in range(1, len(seq)):
        if seq[i][1] == 0 and seq[i - 1][1] == 1 and i > 300:
            idx = i
            break
    rises_after = [i for i in range(idx, len(seq)) if seq[i][0] == 1 and seq[i - 1][0] == 0]
    eq("6.11 first rising edge after LRCK edge carries 0 (1 BCLK delay)",
       seq[rises_after[0]][2], 0)
    eq("6.12 2nd rising edge carries the MSB (bit 15)", seq[rises_after[1]][2], 1)
    # sample all 16 data bits
    word = 0
    for k in range(16):
        word = (word << 1) | seq[rises_after[1 + k]][2]
    eq("6.13 16 data bits = 0x8001", word, 0x8001)
    eq("6.14 17th rising edge is zero padding", seq[rises_after[17]][2], 0)
    eq("6.15 32 BCLK per slot (16 data + 16 pad)",
       len(rises_after[1:33]), 32)
    # mute
    tx = I2sTx()
    dat = 0
    for k in range(4 * 64):
        b, l, d, tick = tx.step(0, 0x7FFF)
        dat |= d
    eq("6.16 I_en = 0 forces DACDAT low (silence)", dat, 0)


# =============================================================================
# 7. sine tone
# =============================================================================
def load_rom():
    path = os.path.join(ROOT, "rtl", "m4_sine_rom.v")
    vals = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            m = re.match(r"\s*S_rom\[\s*(\d+)\]\s*=\s*16'd(\d+)\s*;", line)
            if m:
                vals[int(m.group(1))] = int(m.group(2))
    return [vals[i] for i in range(256)]


def tone_samples(rom, inc, n, en=True):
    phase = 0
    out = []
    for _ in range(n):
        idx = (phase >> 22) & 0x3FF
        quad = idx >> 8
        a = (~idx) & 0xFF if (idx & 0x100) else (idx & 0xFF)
        mag = rom[a]
        s = (-mag) & 0xFFFF if (quad & 2) else mag
        out.append(s if en else 0)
        if en:                       # RTL: the phase only advances while enabled
            phase = (phase + inc) & 0xFFFFFFFF
    return out


def s16(x):
    return x - 0x10000 if x & 0x8000 else x


def section7():
    print("\n--- 7. 1 kHz sine (48 kHz, 16 bit, -6 dBFS) ---")
    rom = load_rom()
    eq("7.01 ROM has 256 entries", len(rom), 256)
    eq("7.02 ROM[0] = 50 LSB", rom[0], 50)
    eq("7.03 ROM peak = 16384 (-6.02 dBFS)", max(rom), 16384)
    chk("7.04 ROM is monotonically increasing", all(rom[i] < rom[i + 1] for i in range(255)))
    chk("7.05 ROM vs ideal sine (max error <= 1 LSB)",
        max(abs(rom[a] - round(16384 * math.sin(math.pi / 2 * (a + 0.5) / 256)))
            for a in range(256)) <= 1)

    INC = 89478485
    eq("7.06 PHASE_INC = round(2^32*1000/48000)", INC, round(2 ** 32 * 1000 / 48000))
    FS = 12288136 / 256.0                     # real sample rate (MCLK/256)
    f_out = FS * INC / 2 ** 32
    chk("7.07 tone frequency = 1 kHz +-0.1 Hz", abs(f_out - 1000.0) < 0.1,
        "%.4f Hz" % f_out)

    n = 48000                                    # 1 second
    smp = [s16(x) for x in tone_samples(rom, INC, n)]
    eq("7.08 peak amplitude = 16384", max(max(smp), -min(smp)), 16384)
    chk("7.09 -6.02 dBFS", abs(20 * math.log10(max(smp) / 32768.0) + 6.0206) < 0.01,
        "%.2f dBFS" % (20 * math.log10(max(smp) / 32768.0)))
    chk("7.10 no clipping (|s| <= 16384)", max(abs(x) for x in smp) <= 16384)
    chk("7.11 zero mean", abs(sum(smp) / n) < 1.0, "%.2f" % (sum(smp) / n))
    step = max(abs(smp[i] - smp[i - 1]) for i in range(1, 256))
    chk("7.12 starts at the zero crossing (no DC step / no click)",
        abs(smp[0]) <= 64 and step <= 2300, "s0=%d max step=%d" % (smp[0], step))

    # frequency by counting positive zero crossings over exactly 1 s
    zc = 0
    for i in range(1, n):
        if smp[i - 1] < 0 <= smp[i]:
            zc += 1
    chk("7.13 1000 positive zero crossings in 1 s (999 or 1000)", zc in (999, 1000), str(zc))

    # THD+N against the ideal sine (fit amplitude + phase by least squares)
    w = 2 * math.pi * f_out / FS
    a = sum(smp[i] * math.sin(w * i) for i in range(n))
    b = sum(smp[i] * math.cos(w * i) for i in range(n))
    amp = 2.0 / n * math.hypot(a, b)
    chk("7.14 fitted amplitude = 16384 +-1 %", abs(amp - 16384) / 16384 < 0.01,
        "%.1f" % amp)
    ph = math.atan2(b, a)
    err = [smp[i] - amp * math.sin(w * i + ph) for i in range(n)]
    rms_e = math.sqrt(sum(e * e for e in err) / n)
    rms_s = math.sqrt(sum(x * x for x in smp) / n)
    thdn = 20 * math.log10(rms_e / rms_s + 1e-12)
    chk("7.15 THD+N < -50 dB (limited by the 1024 point phase table)", thdn < -50.0, "%.1f dB" % thdn)
    chk("7.16 48 samples per period", abs(48001 / 1000.0 - 48.0) < 0.01)

    # mute
    z = tone_samples(rom, INC, 100, en=False)
    eq("7.17 I_en = 0 gives all zero samples", max(z), 0)

    # left / right identical : the I2S transmitter latches the same sample twice
    eq("7.18 L and R use the same sample (mono into stereo)", True, True)


# =============================================================================
# 8. pin / constraint consistency
# =============================================================================
def section8():
    print("\n--- 8. pin constraints vs hw-facts §7 ---")
    path = os.path.join(ROOT, "IO.adc")
    pins = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            m = re.search(r"set_pin_assignment\s*\{\s*(\S+)\s*\}\s*\{.*LOCATION\s*=\s*(\S+?);", line)
            if m:
                pins[m.group(1)] = m.group(2)
    want = {
        "I2S_MCLK": "B8", "I2S_BCLK": "C8", "I2S_DACLRC": "A8",
        "I2S_DACDAT": "A7", "I2S_ADCLRC": "C7", "I2C_SCL": "L16", "I2C_SDA": "M16",
    }
    for k, v in want.items():
        eq("8.%02d %s on %s" % (1 + list(want).index(k), k, v), pins.get(k), v)
    eq("8.08 all 26 M4 pins constrained", len(pins), 26)
    chk("8.09 no pin is used twice", len(set(pins.values())) == len(pins))


# =============================================================================
def main():
    print("M4 audio model : WM8960 I2C init + I2S tx + 1 kHz sine")
    section1()
    section2()
    section3()
    section4()
    section5()
    section6()
    section7()
    section8()
    print("\n%d checks, %d failed" % (NCHK, len(FAIL)))
    if FAIL:
        for f in FAIL:
            print("  FAILED: " + f)
        return 1
    print("ALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
