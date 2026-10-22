#-----------------------------------------------------------------------------
# timing.sdc  --  m0_720p probe (1280x720, vendor pll_hdmi1_4b clocking)
#
#  Expected clocks
#      clk_50m    : 50.000 MHz, period 20.000 ns  (board oscillator K14)
#      pixel_clk  : 73.333 MHz, period 13.636 ns  (VCO 1100 / 15)
#      serial_clk : 366.667 MHz, period  2.727 ns (VCO 1100 / 3, 90 deg)
#
#  TD rejects -divide_by together with -multiply_by in one command
#  (USR-8157/USR-8159), so the PLL outputs are derived in two steps:
#      clk  --x22--> (clkc[0] tap)  --/15--> pixel_clk  --x5--> serial_clk
#  The first step only establishes the 1100 MHz VCO reference on the unused
#  C0 tap; the two clocks that actually matter are exact.
#-----------------------------------------------------------------------------

create_clock -name clk_50m -period 20.000 -waveform {0 10.000} [get_ports {clk}]

# 50 * 22 = 1100 MHz (VCO), declared on the unused C0 tap
create_generated_clock -name clk_vco -source [get_ports {clk}] -multiply_by 22 \
    [get_pins {u_pll/pll_inst.clkc[0]}]

# 1100 / 15 = 73.333 MHz pixel clock
create_generated_clock -name pixel_clk -source [get_pins {u_pll/pll_inst.clkc[0]}] \
    -divide_by 15 \
    [get_pins {u_pll/pll_inst.clkc[1]}]

# 1100 / 3 = 366.667 MHz serial clock (10:1 TMDS with DDR output).
# Derived from the same 1100 MHz tap because TD refuses to chain a generated
# clock from the pixel_clk pin itself (USR-8159).
create_generated_clock -name serial_clk -source [get_pins {u_pll/pll_inst.clkc[0]}] \
    -divide_by 3 \
    [get_pins {u_pll/pll_inst.clkc[2]}]

set_clock_groups -exclusive \
    -group [get_clocks {clk_50m}] \
    -group [get_clocks {pixel_clk}] \
    -group [get_clocks {serial_clk}]
