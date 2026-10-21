#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""model_m4_ctrl.py -- offline model of the M3 interaction and 7 segment logic.

There is no Verilog simulator on this machine (see m2-report.md section 10), so
the M3 additions are verified the way M1/M2 were: the RTL behaviour is copied
into Python and exercised with directed tests, and every check is printed.

Two models, both taken line by line from the RTL:

  KeyCtrl   rtl/m4_video_src.v   key 2FF sync + 2^N debounce, long press
                                 detector, short press on release, pause
                                 toggle, frame based slide show timer,
                                 next/previous toggles + their CDC.

  Seg7      rtl/m4_seg7.v        status filter (2 consecutive 1 kHz samples),
           rtl/m4_hc595.v        digit content mux, 1 kHz scan, active low
                                 decode, and the 16 bit {seg,sel} frame that
                                 the two 74HC595 shift out MSB first.

The model is cycle accurate but uses SCALED parameters (debounce length, long
press length, frames per image, frame length), so a few thousand cycles cover
whole scenarios.  The real time constants follow from the real parameters and
are checked arithmetically at the end (section 4).

Run:  python sim\\model_m4_ctrl.py [-v]
"""

import sys

VERBOSE = "-v" in sys.argv

# ---------------------------------------------------------------------------
# 0. real parameters (as instantiated in m4_top / m4_video_src / m4_seg7)
# ---------------------------------------------------------------------------
CLK_HZ        = 25_000_000        # pixel clock
HTOTAL        = 800
VTOTAL        = 525
FRAME_CLKS    = HTOTAL * VTOTAL    # 420 000 pixel clocks = 16.800 ms
DEB_CLKS      = 1 << 18            # 262 144 clocks = 10.49 ms
HOLD_CLKS     = 25_000_000         # 1.000 s
AUTO_FRAMES   = 179                # 179 x 16.8 ms = 3.0072 s
SCAN_DIV      = 25_000             # 1 kHz scan
HC_DIV        = 5                  # 595 half bit period = 5 clocks (2.5 MHz)
FAT_MAX       = 16                 # MAXF in m4_fat_bmp.v

# segment codes, active low, bit 6..0 = g,f,e,d,c,b,a  (vendor HEX8 table)
SEG = {
    0x0: 0b1000000, 0x1: 0b1111001, 0x2: 0b0100100, 0x3: 0b0110000,
    0x4: 0b0011001, 0x5: 0b0010010, 0x6: 0b0000010, 0x7: 0b1111000,
    0x8: 0b0000000, 0x9: 0b0010000, 0xA: 0b0001000, 0xB: 0b0000011,
    0xC: 0b1000110, 0xD: 0b0100001, 0xE: 0b0000110, 0xF: 0b0111111,
}
BLANK_SEG = 0b1111111

RESULTS = []


def check(name, cond, detail=""):
    RESULTS.append((name, bool(cond), detail))
    if VERBOSE or not cond:
        print("  %-4s %s%s" % ("PASS" if cond else "FAIL", name,
                               ("   [" + detail + "]") if detail else ""))


def summary():
    npass = sum(1 for _, ok, _ in RESULTS if ok)
    nfail = len(RESULTS) - npass
    print("\n%d checks, %d PASS, %d FAIL" % (len(RESULTS), npass, nfail))
    for name, ok, detail in RESULTS:
        if not ok:
            print("  FAILED: %s  %s" % (name, detail))
    return nfail == 0


# ---------------------------------------------------------------------------
# 1. key debounce + long press + pause + slide show timer
#    (rtl/m4_video_src.v)
# ---------------------------------------------------------------------------
class KeyCtrl(object):
    """Cycle model of the M3 interaction part of m4_video_src.v.

    hold_clks / auto_frames / frame_clks / deb_max are the scaled parameters,
    the logic itself is a copy of the RTL.
    """

    def __init__(self, hold_clks=6, auto_frames=3, frame_clks=7, deb_max=3):
        self.hold_clks = hold_clks
        self.auto_frames = auto_frames
        self.frame_clks = frame_clks
        self.deb_max = deb_max

        # 2FF synchronisers (raw -> *_d1 -> *_d2)
        self.k0_d1 = self.k0_d2 = 1
        self.k1_d1 = self.k1_d2 = 1

        self.stb = [1, 1]          # 1 = released
        self.stb_d = [1, 1]
        self.cnt = [0, 0]

        self.hold_cnt = 0
        self.hold_done = False
        self.paused = False

        # registered one cycle pulses (RTL: S_next_pulse / S_prev_pulse)
        self.key_rel_prev = [0, 0]
        self.hold_done_prev = False
        self.next_pulse = 0
        self.prev_pulse = 0

        self.kn = 0
        self.kp = 0
        self.auto_cnt = 0
        self.ready_pulse = 0
        self.has_img = 1
        self.pause_ev = 0

        # observability
        self.n_next = 0
        self.n_prev = 0
        self.pause_events = 0
        self.cycles = 0
        self.frame_phase = 0

    # -- one 25 MHz clock ---------------------------------------------------
    def step(self, key0_n=1, key1_n=1):
        self.cycles += 1

        # frame tick (raster vstart)
        self.frame_phase = (self.frame_phase + 1) % self.frame_clks
        vstart = (self.frame_phase == 0)

        # ---- 2FF sync of the two keys
        self.k0_d1, self.k0_d2 = key0_n, self.k0_d1
        self.k1_d1, self.k1_d2 = key1_n, self.k1_d1
        s = [self.k0_d2, self.k1_d2]

        press = [0, 0]
        rel = [0, 0]
        for k in (0, 1):
            if s[k] != self.stb[k]:
                if self.cnt[k] == self.deb_max:
                    self.cnt[k] = 0
                    self.stb[k] = s[k]          # debounced edge
                else:
                    self.cnt[k] += 1
            else:
                self.cnt[k] = 0
            press[k] = self.stb_d[k] & (1 - self.stb[k])
            rel[k] = (1 - self.stb_d[k]) & self.stb[k]
        self.stb_d = list(self.stb)

        # ---- long press of KEY0
        self.pause_ev = 0
        if press[0]:
            self.hold_cnt = 0
            self.hold_done = False
        elif (not self.stb[0]) and (not self.hold_done):
            if self.hold_cnt >= (self.hold_clks - 1):
                self.hold_done = True
                self.paused = not self.paused
                self.pause_ev = 1
                self.pause_events += 1
            else:
                self.hold_cnt += 1

        # ---- short press pulses (registered, one cycle)
        self.next_pulse = self.key_rel_prev[0] and (not self.hold_done_prev)
        self.prev_pulse = self.key_rel_prev[1]
        self.key_rel_prev = list(rel)
        self.hold_done_prev = self.hold_done

        # ---- slide show timer
        play = (not self.paused) and self.has_img
        auto_fire = vstart and play and (self.auto_cnt >= self.auto_frames - 1)
        timer_rst = (self.ready_pulse or self.next_pulse or self.prev_pulse
                     or self.pause_ev or auto_fire)

        if timer_rst:
            self.auto_cnt = 0
        elif vstart and self.auto_cnt < self.auto_frames - 1:
            self.auto_cnt += 1

        # ---- toggles to the 100 MHz loader
        if (self.next_pulse or auto_fire):
            self.kn ^= 1
            self.n_next += 1
        if self.prev_pulse:
            self.kp ^= 1
            self.n_prev += 1

        self.ready_pulse = 0

    def run(self, n, key0_n=1, key1_n=1):
        for _ in range(n):
            self.step(key0_n, key1_n)

    # -- helpers ------------------------------------------------------------
    def press_short(self, k=0, hold_cycles=None):
        """Press a key for hold_cycles (default: well below the long threshold)."""
        if hold_cycles is None:
            hold_cycles = max(2, (self.hold_clks // 2))
        key = (0 if k == 0 else 1)
        args = [1, 1]
        args[key] = 0
        self.run(self.deb_max + hold_cycles + 2, *args)
        self.run(self.deb_max + 4, 1, 1)

    def press_long(self, k=0, extra=4):
        key = (0 if k == 0 else 1)
        args = [1, 1]
        args[key] = 0
        self.run(self.deb_max + self.hold_clks + extra, *args)
        self.run(self.deb_max + 4, 1, 1)

    def hold_key(self, k=0, cycles=None):
        key = (0 if k == 0 else 1)
        args = [1, 1]
        args[key] = 0
        self.run(cycles, *args)


# ---------------------------------------------------------------------------
# 2. loader stub: the 100 MHz FSM samples the key toggles only in S_KEY
#    (rtl/m4_fat_bmp.v: S_key_next = S_kn_s[1] ^ S_kn_s[2], used in S_KEY)
# ---------------------------------------------------------------------------
class LoaderStub(object):
    def __init__(self, load_cycles=40):
        self.sync = 0                  # 3FF then xor edge -> model with 1FF
        self.sync_d = 0
        self.state = "KEY"
        self.timer = 0
        self.load_cycles = load_cycles
        self.steps = 0
        self.dropped = 0

    def step(self, kn_tog):
        # 3 FF synchroniser + xor of the last two (1 cycle pulse)
        pulse = self.sync ^ self.sync_d
        self.sync_d = self.sync
        self.sync = kn_tog

        if self.state == "KEY":
            if pulse:
                self.state = "LOAD"
                self.timer = self.load_cycles
                self.steps += 1
        else:
            if pulse:
                self.dropped += 1        # arrives outside S_KEY -> lost
            self.timer -= 1
            if self.timer <= 0:
                self.state = "KEY"


# ---------------------------------------------------------------------------
# 3. 7 segment content + scan + 595 frame  (rtl/m4_seg7.v, rtl/m4_hc595.v)
# ---------------------------------------------------------------------------
class Seg7(object):
    def __init__(self, dig_rev=0):
        self.num = 0x0000          # latched IMGnnnn digits
        self.have_num = False      # at least one page has completed since reset
        self.dig_rev = dig_rev

    # -- status filter: accept a value two consecutive 1 kHz samples agree on
    @staticmethod
    def filter_bus(samples):
        """samples: list of (mounted, err, count, index, key) tuples per tick."""
        stat = (0, 0, 0, 0, 0)
        d1 = d2 = (0, 0, 0, 0, 0)
        for s in samples:
            d1, d2 = d2, d1
            d1 = s                            # 2FF output of this tick
            if d1 == d2:
                stat = d2
        return stat

    def latch(self, mounted, err, count, index, key):
        self.have_num = True
        if key != 0xFFFF:
            self.num = key
        else:
            v = index + 1
            lo = (v - 10) if v >= 10 else v
            hi = 1 if v >= 10 else 0
            self.num = (hi << 4) | lo

    # -- one digit of the frame
    def digit(self, dig, mounted, err, count, busy, paused, blink):
        n = self.num
        tok = (not self.have_num) or (count == 0) or (err == 4)
        tok_err = err != 0

        c_lo = (count - 10) if count >= 10 else count
        c_hi = 1 if count >= 10 else 0

        d = [n & 0xF, (n >> 4) & 0xF, (n >> 8) & 0xF, (n >> 12) & 0xF,
             0x10, 0x10, c_lo, c_hi]
        if tok:
            d = [((0 << 3) | err) if tok_err else 0xF,
                 (0xE if tok_err else 0xF),
                 0x10, 0x10, 0x10, 0x10, 0x10, 0x10]

        code = d[dig]
        blank = (paused and blink) or (code & 0x10)
        dot_on = (dig == 0) and busy
        seg = 0xFF if blank else (((0 if dot_on else 1) << 7) |
                                  SEG[code & 0xF])
        sel = ((1 << dig) if self.dig_rev == 0 else (0x80 >> dig)) & 0xFF
        return seg & 0xFF, sel

    def frame(self, dig, *args):
        seg, sel = self.digit(dig, *args)
        return (seg << 8) | sel


def shift_595(frame):
    """Bit serial model of the two cascaded 74HC595 (MSB first).

    Returns (seg_byte, sel_byte) as latched by RCLK after 16 SCLK rising edges.
    The first 8 bits shifted travel through the near chip into the far one, so
    after 16 clocks the far chip holds the first byte and the near chip the
    second one.
    """
    sr = 0
    for i in range(15, -1, -1):
        sr = ((sr << 1) | ((frame >> i) & 1)) & 0xFFFF
    # sr[15:8] = the first 8 bits shifted (they travelled through the near chip
    # into the far one = the segment driver), sr[7:0] = the last 8 (near chip =
    # the digit select driver)
    return (sr >> 8) & 0xFF, sr & 0xFF


# ---------------------------------------------------------------------------
# 4. tests
# ---------------------------------------------------------------------------
def keys_only(**kw):
    """A controller with auto play effectively disabled (key tests only)."""
    kw.setdefault("auto_frames", 1 << 20)
    kw.setdefault("frame_clks", 4096)
    return KeyCtrl(**kw)


def test_debounce():
    print("\n[1] key debounce and press/release events (m4_video_src.v)")
    c = keys_only(hold_clks=1000, deb_max=3)
    check("reset state: both keys released, no toggles",
          c.stb == [1, 1] and c.kn == 0 and c.kp == 0)

    # a glitch shorter than the debounce filter must be ignored
    c.run(2, 0, 1)
    c.run(10, 1, 1)
    check("glitch < debounce length produces no event",
          c.n_next == 0 and c.stb == [1, 1], "n_next=%d" % c.n_next)

    # a real press produces exactly one next toggle, on release
    c2 = keys_only(hold_clks=1000, deb_max=3)
    c2.hold_key(0, 2 + 6)
    check("pressed but not released: no step yet", c2.n_next == 0)
    c2.run(6, 1, 1)
    check("short press -> exactly one next toggle on release",
          c2.n_next == 1, "n_next=%d" % c2.n_next)
    check("prev toggle untouched by KEY0", c2.n_prev == 0)

    # KEY1 -> previous
    c2.hold_key(1, 2 + 6)
    c2.run(6, 1, 1)
    check("short press KEY1 -> one prev toggle", c2.n_prev == 1)
    check("KEY1 does not step forward", c2.n_next == 1)

    # hold longer than the debounce but shorter than the long press window
    c3 = keys_only(hold_clks=50, deb_max=3)
    c3.hold_key(0, c3.hold_clks - 4)
    c3.run(6, 1, 1)
    check("press just below the long press threshold still steps",
          c3.n_next == 1 and c3.paused is False,
          "n_next=%d paused=%s" % (c3.n_next, c3.paused))


def test_long_press():
    print("\n[2] long press = pause / resume (KEY0)")
    c = keys_only(hold_clks=20, deb_max=3)
    # hold until the threshold is crossed, keep holding a bit, then release
    c.hold_key(0, c.deb_max + 20 + 10)
    check("long press toggles pause while the key is still down",
          c.paused is True, "paused=%s" % c.paused)
    check("long press does NOT step to the next image",
          c.n_next == 0, "n_next=%d" % c.n_next)
    c.run(c.deb_max + 8, 1, 1)
    check("the release after a long press is swallowed",
          c.n_next == 0 and c.paused is True, "n_next=%d" % c.n_next)
    check("exactly one pause event for one long press", c.pause_events == 1)

    # a second long press resumes
    c.hold_key(0, c.deb_max + 20 + 10)
    c.run(c.deb_max + 8, 1, 1)
    check("second long press resumes play", c.paused is False)
    check("still no next toggle from either long press", c.n_next == 0)
    check("two long presses = two pause events", c.pause_events == 2)

    # long press of KEY1 has no pause action
    c2 = keys_only(hold_clks=20, deb_max=3)
    c2.hold_key(1, c2.deb_max + 40)
    c2.run(c2.deb_max + 8, 1, 1)
    check("KEY1 long press does not change the play mode",
          c2.paused is False and c2.pause_events == 0)
    check("KEY1 long press still steps back exactly once", c2.n_prev == 1)


def test_auto():
    print("\n[3] automatic slide show timer")
    c = KeyCtrl(hold_clks=1000, auto_frames=3, frame_clks=7, deb_max=3)
    frames = 0
    while c.n_next == 0 and frames < 100:
        c.run(7)
        frames += 1
    check("auto advance fires after exactly AUTO_FRAMES frame starts",
          frames == 3 and c.n_next == 1, "frames=%d" % frames)

    # the auto step restarts the counter (no repeated toggles while the loader
    # is busy: the next fire is another full slot later)
    frames = 0
    while c.n_next == 1 and frames < 100:
        c.run(7)
        frames += 1
    check("auto step restarts the timer itself (one toggle per slot)",
          frames == 3 and c.n_next == 2, "frames=%d" % frames)

    # the loader completes a page (ready pulse) -> the timer restarts
    c.ready_pulse = 1
    c.step()
    frames = 0
    while c.n_next == 2 and frames < 100:
        c.run(7)
        frames += 1
    check("page complete restarts the timer (full slot again)",
          frames == 3, "frames=%d" % frames)

    # paused (by a long press) -> never advances
    c2 = KeyCtrl(hold_clks=30, auto_frames=5, frame_clks=7, deb_max=3)
    c2.press_long(0)
    n0 = c2.n_next
    check("long press pauses the slide show", c2.paused is True)
    c2.run(7 * 40)
    check("paused: no automatic advance", c2.n_next == n0)

    # resume (second long press) -> a full slot, not an immediate jump
    c2.press_long(0)
    n0 = c2.n_next
    check("second long press resumes", c2.paused is False)
    c2.run(7 * 2)
    check("resume does not jump immediately", c2.n_next == n0,
          "n_next=%d" % c2.n_next)
    c2.run(7 * 4)
    check("resume: advances after a full slot again", c2.n_next == n0 + 1,
          "n_next=%d" % c2.n_next)

    # no image list -> no auto advance (empty / missing card)
    c3 = KeyCtrl(hold_clks=1000, auto_frames=2, frame_clks=5, deb_max=3)
    c3.has_img = 0
    c3.run(5 * 40)
    check("no image list: auto play inhibited", c3.n_next == 0)

    # a manual step restarts the timer
    c4 = KeyCtrl(hold_clks=1000, auto_frames=4, frame_clks=5, deb_max=3)
    c4.run(5 * 3)                      # 3 of 4 frames
    c4.press_short(0, hold_cycles=4)   # manual next
    n0 = c4.n_next
    c4.run(5 * 3)
    check("manual step restarts the 3 s slot (no early auto step)",
          c4.n_next == n0, "n_next=%d" % c4.n_next)
    c4.run(5 * 2)
    check("after the restarted slot the auto step happens",
          c4.n_next == n0 + 1, "n_next=%d" % c4.n_next)


def test_key_vs_load():
    print("\n[4] keys during a load are ignored (100 MHz FSM samples S_KEY only)")
    c = keys_only(hold_clks=1000, deb_max=3)
    ld = LoaderStub(load_cycles=400)
    for _ in range(5):
        c.press_short(0, hold_cycles=3)
        for _ in range(20):
            c.step()
            ld.step(c.kn)
    check("a burst of 5 presses during one load yields exactly one step",
          ld.steps == 1, "steps=%d dropped=%d" % (ld.steps, ld.dropped))
    check("the extra presses were dropped, not queued",
          ld.dropped >= 1 and c.n_next >= 5,
          "dropped=%d n_next=%d" % (ld.dropped, c.n_next))

    # after the load finishes the next press works again
    for _ in range(400):
        c.step()
        ld.step(c.kn)
    check("the loader is idle again", ld.state == "KEY")
    c.press_short(0, hold_cycles=3)
    for _ in range(60):
        c.step()
        ld.step(c.kn)
    check("press after the load ends is accepted", ld.steps == 2,
          "steps=%d" % ld.steps)


def test_seg7():
    print("\n[5] 7 segment content, scan and 595 frame")
    s = Seg7()

    # ---- normal: IMG0007 with 3 images -> "0007" on d3..d0, "03" on d7,d6
    s.latch(1, 0, 3, 6, 0x0007)
    check("IMG0007 latches as 4 BCD digits 0,0,0,7", s.num == 0x0007)
    seg0, sel0 = s.digit(0, 1, 0, 3, 0, 0, 0)
    seg1, _ = s.digit(1, 1, 0, 3, 0, 0, 0)
    seg2, _ = s.digit(2, 1, 0, 3, 0, 0, 0)
    seg3, _ = s.digit(3, 1, 0, 3, 0, 0, 0)
    check("d0 shows '7'", seg0 == (0x80 | SEG[7]), "seg=0x%02X" % seg0)
    check("d1..d3 show '0'", seg1 == seg2 == seg3 == (0x80 | SEG[0]))
    seg6, _ = s.digit(6, 1, 0, 3, 0, 0, 0)
    seg7, _ = s.digit(7, 1, 0, 3, 0, 0, 0)
    check("d6 = count ones (3)", seg6 == (0x80 | SEG[3]))
    check("d7 = count tens (0)", seg7 == (0x80 | SEG[0]))
    check("unused digits d4/d5 are blank",
          s.digit(4, 1, 0, 3, 0, 0, 0)[0] == 0xFF and
          s.digit(5, 1, 0, 3, 0, 0, 0)[0] == 0xFF)
    check("digit select is one hot, ascending",
          [s.digit(d, 1, 0, 3, 0, 0, 0)[1] for d in range(8)]
          == [1, 2, 4, 8, 16, 32, 64, 128])
    check("frame = {seg, sel} with seg in bits 15..8",
          s.frame(0, 1, 0, 3, 0, 0, 0) == ((0x80 | SEG[7]) << 8) | 1)

    # ---- 12 images, IMG0012 -> count 12 = "12" on d7,d6
    s.latch(1, 0, 12, 11, 0x0012)
    check("IMG0012 -> digits 0,0,1,2",
          [(s.num >> (4 * i)) & 0xF for i in range(4)] == [2, 1, 0, 0])
    check("count 12 -> d6 = 2, d7 = 1",
          s.digit(6, 1, 0, 12, 0, 0, 0)[0] == (0x80 | SEG[2]) and
          s.digit(7, 1, 0, 12, 0, 0, 0)[0] == (0x80 | SEG[1]))

    # ---- non IMGnnnn name -> fall back to the 1 based list index
    s.latch(1, 0, 16, 9, 0xFFFF)
    check("key 0xFFFF falls back to index+1 = 10 -> '0010'",
          [(s.num >> (4 * i)) & 0xF for i in range(4)] == [0, 1, 0, 0])
    s.latch(1, 0, 16, 15, 0xFFFF)
    check("index 15 -> '0016'",
          [(s.num >> (4 * i)) & 0xF for i in range(4)] == [6, 1, 0, 0])

    # ---- special states
    # boot: no page has completed yet, so nothing is known about the picture
    s3 = Seg7()
    check("boot (no page yet) shows dash dash and no number",
          s3.digit(0, 1, 0, 3, 0, 0, 0)[0] == (0x80 | SEG[0xF]) and
          s3.digit(1, 1, 0, 3, 0, 0, 0)[0] == (0x80 | SEG[0xF]) and
          all(s3.digit(d, 1, 0, 3, 0, 0, 0)[0] == 0xFF
              for d in (2, 3, 4, 5, 6, 7)))
    s3.latch(1, 0, 3, 0, 0x0001)
    check("after the first page completes the number appears",
          s3.digit(0, 1, 0, 3, 0, 0, 0)[0] == (0x80 | SEG[1]))

    s.latch(0, 1, 0, 0, 0xFFFF)
    check("no card (err=1): d1='E', d0='1'",
          s.digit(1, 0, 1, 0, 0, 0, 0)[0] == (0x80 | SEG[0xE]) and
          s.digit(0, 0, 1, 0, 0, 0, 0)[0] == (0x80 | SEG[1]))
    check("error token blanks every other digit",
          all(s.digit(d, 0, 1, 0, 0, 0, 0)[0] == 0xFF for d in (2, 3, 4, 5, 6, 7)))
    check("not FAT32 (err=2) -> 'E2'",
          s.digit(0, 1, 2, 0, 0, 0, 0)[0] == (0x80 | SEG[2]))
    check("no BMP file (err=3) -> 'E3'",
          s.digit(0, 1, 3, 0, 0, 0, 0)[0] == (0x80 | SEG[3]))
    check("mounting / no error -> '-' '-'",
          s.digit(0, 0, 0, 0, 0, 0, 0)[0] == (0x80 | SEG[0xF]) and
          s.digit(1, 0, 0, 0, 0, 0, 0)[0] == (0x80 | SEG[0xF]))
    check("dash uses only segment g (active low)", SEG[0xF] == 0b0111111)
    s.latch(1, 4, 5, 2, 0x0003)
    check("all candidates bad (err=4) -> 'E4'",
          s.digit(0, 1, 4, 5, 0, 0, 0)[0] == (0x80 | SEG[4]))
    check("err=6 (file too short) still shows the picture number",
          s.digit(0, 1, 6, 5, 0, 0, 0)[0] == (0x80 | SEG[3]))

    # ---- loading dot on d0 only
    s.latch(1, 0, 3, 0, 0x0001)
    check("busy lights the DP of d0",
          (s.digit(0, 1, 0, 3, 1, 0, 0)[0] & 0x80) == 0)
    check("busy does not light any other DP",
          all(s.digit(d, 1, 0, 3, 1, 0, 0)[0] & 0x80 for d in range(1, 8)))

    # ---- paused blink blanks everything
    check("paused + blink phase = whole display blank",
          all(s.digit(d, 1, 0, 3, 1, 1, 1)[0] == 0xFF for d in range(8)))
    check("paused + visible phase keeps the content",
          s.digit(0, 1, 0, 3, 0, 1, 0)[0] == (0x80 | SEG[1]))

    # ---- DIG_REV bring-up knob mirrors the digit selects
    s2 = Seg7(dig_rev=1)
    check("DIG_REV=1 mirrors the select lines",
          [s2.digit(d, 1, 0, 3, 0, 0, 0)[1] for d in range(8)]
          == [128, 64, 32, 16, 8, 4, 2, 1])

    # ---- status filter: mixed 100 MHz samples are rejected
    bus = [(1, 0, 0, 0, 0xFFFF)] * 2 + [(1, 2, 0, 0, 0xFFFF)] + \
          [(1, 3, 0, 0, 0xFFFF)] * 3 + [(1, 3, 7, 0, 0x0005)] + \
          [(1, 3, 7, 0, 0x0005)] * 3
    st = Seg7.filter_bus(bus)
    check("filter rejects one sample wide glitches, accepts stable values",
          st == (1, 3, 7, 0, 0x0005), str(st))
    torn = [(1, 0, 3, 0, 0x0001)] * 2 + [(1, 3, 3, 0, 0x0001)] * 4
    check("filter never accepts a torn value",
          Seg7.filter_bus(torn) == (1, 3, 3, 0, 0x0001))


def test_595():
    print("\n[6] 74HC595 frame and shift timing (m4_hc595.v)")
    s = Seg7()
    s.latch(1, 0, 3, 0, 0x0001)
    frame = s.frame(0, 1, 0, 3, 0, 0, 0)
    seg, sel = shift_595(frame)
    check("segment byte is shifted first (frame bits 15..8)",
          (frame >> 8) == (0x80 | SEG[1]))
    check("after 16 clocks the far chip holds seg, the near chip holds sel",
          seg == ((0x80 | SEG[1]) & 0xFF) and sel == 0x01,
          "seg=0x%02X sel=0x%02X" % (seg, sel))
    swapped = shift_595(((frame & 0xFF) << 8) | (frame >> 8))
    check("a {sel,seg} frame would swap the two chips (order matters)",
          swapped != (seg, sel), "%s" % (swapped,))
    # all eight digits survive the frame packing
    ok = True
    for d in range(8):
        f = s.frame(d, 1, 0, 3, 0, 0, 0)
        sg, sl = shift_595(f)
        ok = ok and (sl == (1 << d)) and (sg == ((f >> 8) & 0xFF))
    check("all 8 digit slots shift out with the right select", ok)
    # timing: transfer length and SCLK frequency
    steps = 16 * 2 + 2
    t_clk = steps * HC_DIV
    check("transfer takes %d clocks = %.1f us (well inside the 1 ms slot)"
          % (t_clk, t_clk / 25.0), t_clk == 170 and t_clk < SCAN_DIV,
          "%d clocks" % t_clk)
    check("SCLK = 25 MHz / %d = %.2f MHz" % (2 * HC_DIV, 25.0 / (2 * HC_DIV)),
          abs(25.0 / (2 * HC_DIV) - 2.5) < 1e-9)
    check("transfer finishes in %.1f %% of a digit slot"
          % (100.0 * t_clk / SCAN_DIV), (SCAN_DIV - t_clk) > 100 * t_clk)

def test_real_timing():
    print("\n[7] real time constants (from the real parameters)")
    deb_ms = DEB_CLKS / CLK_HZ * 1e3
    hold_s = HOLD_CLKS / CLK_HZ
    frame_ms = FRAME_CLKS / CLK_HZ * 1e3
    auto_s = AUTO_FRAMES * FRAME_CLKS / CLK_HZ
    scan_hz = CLK_HZ / SCAN_DIV
    check("debounce = 2^18 / 25 MHz = %.2f ms" % deb_ms, abs(deb_ms - 10.49) < 0.01)
    check("long press = %.3f s" % hold_s, abs(hold_s - 1.0) < 1e-9)
    check("frame = %d x %d / 25 MHz = %.4f ms (%.2f Hz)"
          % (HTOTAL, VTOTAL, frame_ms, 1000.0 / frame_ms),
          abs(frame_ms - 16.8) < 1e-9 and abs(1000.0 / frame_ms - 59.5238) < 0.001)
    check("auto advance = %d frames = %.4f s" % (AUTO_FRAMES, auto_s),
          abs(auto_s - 3.0072) < 1e-9)
    check("digit scan = %.0f Hz, refresh = %.1f Hz" % (scan_hz, scan_hz / 8),
          abs(scan_hz - 1000.0) < 1e-9)
    check("blink = 1 kHz / 2^8 = %.2f Hz (0.256 s per half period)"
          % (scan_hz / 256 / 2),
          abs(scan_hz / 256 / 2 - 1.953) < 0.01)
    check("display capacity: 4 digit number + 2 digit total fits 8 digits",
          FAT_MAX <= 99)


def main():
    print("model_m4_ctrl.py -- M3 interaction / 7 segment model")
    print("pixel clock %d Hz, frame %d x %d, %d frames/image"
          % (CLK_HZ, HTOTAL, VTOTAL, AUTO_FRAMES))
    test_debounce()
    test_long_press()
    test_auto()
    test_key_vs_load()
    test_seg7()
    test_595()
    test_real_timing()
    return 0 if summary() else 1


if __name__ == "__main__":
    sys.exit(main())
