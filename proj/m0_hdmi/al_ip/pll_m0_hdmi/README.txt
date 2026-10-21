pll_m0_hdmi  --  M0 HDMI pixel / serial clock PLL
==================================================

Target : EG4S20BG256 (AC208), TD Release_2026.1_SP2
Input  : 50.000 MHz board oscillator on K14

Outputs
  clk0_out : 100.000 MHz   (feedback tap, unused)
  clk1_out :  25.000 MHz   pixel clock   -> video_gen + HDMI core
  clk2_out : 125.000 MHz   serial clock  -> 4 x lane_lvds_10_1 (10:1 TMDS)

How pll_m0_hdmi.v was produced
------------------------------
TD has no scriptable IP generator (`read_ipc_file` only *loads* an IP whose
generated .v already exists), so the PLL was written by copying the vendor
generated files for the very same device and recalculating the dividers:

  * src/5640/sdram_ctrl_4p/Sdram_PLL.v   (board_test) : 50 MHz -> 100 MHz,
        FBCLK_DIV = 20, CLKC0_DIV = 10, FEEDBK_MODE = NOCOMP,
        FEEDBK_PATH = VCO_PHASE_0, loop filter 4/13/4/1/4, VCO = 1000 MHz
  * al_ip/pll_hdmi1_4b/pll_hdmi1_4b.v    (board_test) : shows how a phase
        shifted serial clock is expressed (CLKCn_FPHASE)

The whole structure (EG_PHY_PLL parameter set, loop filter values) is copied
from Sdram_PLL.v, whose VCO is also 1000 MHz with a 50 MHz phase detector --
the only changes are the CLKCn_DIV / CLKCn_CPHASE / CLKC2_FPHASE values.

VCO / divider arithmetic
------------------------
  FEEDBK_MODE = NOCOMP + FEEDBK_PATH = VCO_PHASE_0  (internal feedback)
      Fvco  = FIN * FBCLK_DIV / REFCLK_DIV = 50 * 20 / 1 = 1000 MHz
      CLKCn = Fvco / CLKCn_DIV
  (The external feedback variant CLKC0_EXT used by pll_hdmi1_4b instead gives
   Fvco = FIN * CLKC0_DIV * FBCLK_DIV / REFCLK_DIV, which is D0 times higher.)

      CLKC0_DIV = 10  -> 100.000 MHz
      CLKC1_DIV = 40  ->  25.000 MHz   (pixel, 0 deg)
      CLKC2_DIV =  8  -> 125.000 MHz   (serial, CLKC2_FPHASE = 7)

CLKCn_CPHASE / CLKCn_FPHASE (phase encoding, reverse engineered from the vendor
PLLs; it reproduces every vendor header comment):

      phase = (CLKCn_CPHASE + 1 + CLKCn_FPHASE/8) / CLKCn_DIV * 360 deg

  * 0 deg outputs: the generator always writes CPHASE = DIV - 1, which reduces
    the formula to phase = 45 * FPHASE / DIV.
  * pll_hdmi1_4b.v C2 (DIV=3,  CPHASE=2, FPHASE=6) -> 450 deg =  90 deg  (OK)
  * Sdram_PLL.v    C1 (DIV=10, CPHASE=6, FPHASE=4) ->        = 270 deg  (OK)
  * this design    C2 (DIV=8,  CPHASE=7, FPHASE=7) ->        =  39.375 deg

Phase of the serial clock
-------------------------
CLKCn_FPHASE is a 0..7 fine phase control, one step = VCO period / 8 = 0.125 ns.
The vendor 720p PLL used 90 deg on its 366.67 MHz serial clock
(CLKC2_DIV = 3, CLKC2_FPHASE = 6 -> 6/8 VCO = 0.75 VCO = 90 deg).
For 125 MHz (CLKC2_DIV = 8) 90 deg would need FPHASE = 16, which does not
exist, so the largest legal value 7 is used:
      45 * 7 / 8 = 39.375 deg  =  0.875 ns  of the 8 ns serial period.
TD's own derivation agrees: `derive_pll_clocks` prints
      create_generated_clock -name clkc[2] ... -multiply_by 2.5 -phase 39
The phase shift only moves the serial clock edges away from the pixel clock
edge (it is a sampling margin knob for the pixel -> serial hand over inside
lane_lvds_10_1); data and clock lanes are serialised by identical logic, so it
does not change the TMDS data/clock relationship at the pins.
See docs/research/m0-report.md section 8 for the alternatives (VCO = 500 MHz
would give 78.75 deg) and for what has to be confirmed on the board.

Files
-----
  pll_m0_hdmi.v    the PLL used by the project (listed as a plain Verilog file)
  pll_m0_hdmi.ipc  documentation copy only -- NOT listed in m0_hdmi.al / .prj,
                   see the comment inside it
