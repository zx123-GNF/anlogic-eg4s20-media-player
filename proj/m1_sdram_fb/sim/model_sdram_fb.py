#!/usr/bin/env python
"""
model_sdram_fb.py -- cycle-level behavioural model of the M1 SDRAM frame buffer
                     (no Verilog simulator is available on this machine).

What is modelled
----------------
  * the 100 MHz Sdram_Control_4Port arbitration: one 128-word burst at a time,
    priority RD1 > RD2 > WR1, exactly the priority order of the auto read/write
    control block (Sdram_Control_4Port.v:592-637);
  * the burst cost: 128 data cycles + fixed command/activate/CAS/precharge
    overhead.  The ST counter of the controller runs 0..SC_CL+SC_RCD+LENGTH+1
    = 135, plus the 2-cycle command handshake, so 10 overhead cycles
    (default) is the value derived from the RTL; larger values are used as a
    sensitivity check;
  * the 512-deep asynchronous FIFOs and their thresholds.  UG301 section 14.3
    defines them as absolute used counts (default AF = DEPTH-6):
        WR aempty AE=127  -> a write burst is issued when used > 127
        WR afull  AF=378  -> the producer stops at used >= 378
        RD afull  AF=256  -> a read burst is issued when used < 256
    (the vendor value was 128; M1 raised it to 256, see report section 3.6);
  * the raster: 800x525 at 25 MHz, 640 active pixels x 480 lines = 307200
    words/frame, one word per active pixel on each read port;
  * the writer: one page = 307200 words per frame, started at the frame tick,
    throttled by WR1_FULL and stopping after 307200 words;
  * the ring / page address counters:
        WR1  0 .. 614400  (page A 0..307199, page B 307200..614399)
        RD1  0 .. 307200
        RD2  307200 .. 614400

What is checked
---------------
  1. every burst is issued with >= 128 words queued: that is the property that
     makes "word n -> ring address base+n" exact (the FIFO is a pure delay);
  2. the read FIFOs never run empty while the display consumes
     (an underrun would permanently phase-shift the picture by 1 word);
  3. the write FIFO never overflows;
  4. the read FIFO margin and the total SDRAM utilisation.

Usage:  python model_sdram_fb.py [burst_overhead_cycles] [frames]
"""
import sys

HACTIVE, HBLANK = 640, 160
VACTIVE, VBLANK = 480, 45
HTOTAL, VTOTAL = 800, 525
PIX_DIV = 4                      # 100 MHz controller / 25 MHz pixel clock
FRAME_WORDS = HACTIVE * VACTIVE  # 307200
PAGE_A, PAGE_B = 0, 307200
RING_END = 614400
BURST = 128
FIFO_DEPTH = 512
RD_AF = 256                      # afull_threshold: asserts at used >= 256 (M1: vendor 128 -> 256)
WR_AE = 127                      # aef_threshold : asserts at used <= 127 (absolute)
WR_AF = 378                      # aff_threshold : asserts at used >= 378 (absolute)

FRAME_CLKS = HTOTAL * VTOTAL * PIX_DIV     # 1,680,000 controller clocks


def simulate(overhead, frames=4, verbose=True):
    rd1 = rd2 = wr1 = 0
    addr_rd1, addr_rd2, addr_wr = PAGE_A, PAGE_B, PAGE_A
    bursts = {'rd1': 0, 'rd2': 0, 'wr': 0}
    min_rd1 = min_rd2 = 10 ** 9
    min_rd1_after_start = 10 ** 9
    max_wr = 0
    underrun_rd1 = underrun_rd2 = overrun = short_fifo = 0
    words_written = words_read = 0
    busy = 0
    target = None
    rd_en = False
    remaining = 0            # words left in the current page write

    for clk in range(frames * FRAME_CLKS):
        pix = clk // PIX_DIV
        line = (pix // HTOTAL) % VTOTAL
        col = pix % HTOTAL
        tick   = (clk % PIX_DIV) == 0          # one 25 MHz pixel clock
        active = tick and (line >= VBLANK) and (col >= HBLANK)
        vstart = tick and (line == 0) and (col == 0)

        if vstart:
            frame = clk // FRAME_CLKS
            if frame >= 2:
                rd_en = True
            if frame >= 1 and remaining == 0:
                remaining = FRAME_WORDS        # writer ignores starts while busy

        # ---- display: one word per active pixel on each read port ----------
        if active and rd_en:
            if rd1 > 0:
                rd1 -= 1
                addr_rd1 += 1
                if addr_rd1 >= PAGE_A + FRAME_WORDS:
                    addr_rd1 = PAGE_A
                words_read += 1
            else:
                underrun_rd1 += 1
            if rd2 > 0:
                rd2 -= 1
                addr_rd2 += 1
                if addr_rd2 >= RING_END:
                    addr_rd2 = PAGE_B
                words_read += 1
            else:
                underrun_rd2 += 1

        # ---- writer: 100 MHz, throttled by WR1_FULL ------------------------
        if remaining > 0 and wr1 < WR_AF:
            wr1 += 1
            remaining -= 1
            words_written += 1
            if wr1 > max_wr:
                max_wr = wr1

        # ---- SDRAM controller: one 128 word burst at a time ----------------
        if busy > 0:
            busy -= 1
            if busy == 0:
                if target == 'rd1':
                    rd1 += BURST
                    bursts['rd1'] += 1
                    addr_rd1 += BURST
                    if addr_rd1 >= PAGE_A + FRAME_WORDS:
                        addr_rd1 = PAGE_A
                elif target == 'rd2':
                    rd2 += BURST
                    bursts['rd2'] += 1
                    addr_rd2 += BURST
                    if addr_rd2 >= RING_END:
                        addr_rd2 = PAGE_B
                else:
                    wr1 -= BURST
                    bursts['wr'] += 1
                    addr_wr += BURST
                    if addr_wr >= RING_END:
                        addr_wr = PAGE_A
        else:
            if rd1 < RD_AF:                             # !rd1_afull
                target, busy = 'rd1', BURST + overhead
            elif rd2 < RD_AF:                           # !rd2_afull
                target, busy = 'rd2', BURST + overhead
            elif wr1 > WR_AE:
                target, busy = 'wr', BURST + overhead
            else:
                target = None
            if target == 'wr' and wr1 < BURST:
                short_fifo += 1

        if rd_en:
            min_rd1 = min(min_rd1, rd1)
            min_rd2 = min(min_rd2, rd2)

    used = sum(bursts.values()) * (BURST + overhead)
    if verbose:
        print(f"burst overhead           : {overhead} cycles "
              f"(burst = {BURST + overhead})")
        print(f"frames simulated         : {frames}")
        print(f"bursts rd1 / rd2 / wr    : {bursts['rd1']} / {bursts['rd2']} / {bursts['wr']}")
        print(f"words written / read     : {words_written} / {words_read}")
        print(f"min RD1 FIFO occupancy   : {min_rd1} words "
              f"({min_rd1 * PIX_DIV} controller clocks of margin)")
        print(f"min RD2 FIFO occupancy   : {min_rd2} words")
        print(f"max WR1 FIFO occupancy   : {max_wr} words")
        print(f"read underruns           : rd1={underrun_rd1} rd2={underrun_rd2}")
        print(f"write overruns           : {overrun}")
        print(f"bursts with <128 queued  : {short_fifo}")
        steady = 7200 * (BURST + overhead)   # 2 read ports + 1 write port
        print(f"SDRAM utilisation        : {100.0 * steady / FRAME_CLKS:.1f} % (steady state, 7200 bursts/frame)")
    ok = (underrun_rd1 == 0 and underrun_rd2 == 0 and overrun == 0
          and short_fifo == 0)
    return ok


if __name__ == '__main__':
    overhead = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    frames = int(sys.argv[2]) if len(sys.argv) > 2 else 4
    ok = simulate(overhead, frames)
    print("RESULT:", "OK" if ok else "FAIL")
    sys.exit(0 if ok else 1)
