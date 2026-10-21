#-----------------------------------------------------------------------------
# timing.sdc  --  M0 HDMI 640x480 colour bars (AC208 / EG4S20BG256)
#
#  Clock tree
#      50 MHz board oscillator (K14, port clk)
#          +-> PLL u_pll (EG_PHY_PLL, al_ip/pll_m0_hdmi, VCO = 1000 MHz)
#                +-> clkc[1] =  25.000 MHz  pixel clock  (period 40.000 ns)
#                +-> clkc[2] = 125.000 MHz  serial clock (period  8.000 ns)
#          +-> key/edge synchroniser (2 FFs) -> reset release
#
#  The PLL is kept as a plain Verilog file in this project, so TD sees the
#  EG_PHY_PLL macro as a pass-through of clk_50m and rejects a second primary
#  create_clock on its output ("primary clock ... is on the network of clock
#  clk_50m").  create_generated_clock is the correct SDC construct here; the
#  resulting periods are 40 ns and 8 ns, i.e. exactly 25.000 / 125.000 MHz.
#
#  Clocks are referenced through PLL instance pins (structural names owned by
#  this project) and NOT through synthesised net names like the vendor board
#  test did (get_nets {S_pixel_clk}).
#
#  set_clock_groups -exclusive:
#    * pixel_clk  <-> serial_clk : the 10 bit TMDS word is handed from the
#      pixel domain to the shift register by the self-timed load pulse of
#      lane_lvds_10_1 (~4 serial clocks = 32 ns of margin).  This crossing is
#      not edge-timed by construction; the vendor board test declares the same
#      two clocks exclusive.
#    * clk_50m    <-> both       : the 50 MHz domain only produces the
#      asynchronous reset release (async assert / sync release per domain),
#      so recovery/removal across those domains is not meaningful either.
#-----------------------------------------------------------------------------

create_clock -name clk_50m -period 20.000 -waveform {0 10.000} [get_ports {clk}]

create_generated_clock -name pixel_clk \
    -source [get_ports {clk}] -divide_by 2 \
    [get_pins {u_pll/pll_inst.clkc[1]}]

# 125.000 MHz = 5 x 25.000 MHz (10:1 TMDS with a DDR output -> 2 bits per
# serial clock).  TD accepts only one of -divide_by / -multiply_by per command,
# so the serial clock is derived from the pixel clock.
create_generated_clock -name serial_clk \
    -source [get_pins {u_pll/pll_inst.clkc[1]}] -multiply_by 5 \
    [get_pins {u_pll/pll_inst.clkc[2]}]

set_clock_groups -exclusive \
    -group [get_clocks {clk_50m}] \
    -group [get_clocks {pixel_clk}] \
    -group [get_clocks {serial_clk}]
