#-----------------------------------------------------------------------------
# timing.sdc  --  M1 SDRAM frame buffer -> HDMI 640x480 (AC208 / EG4S20BG256)
#
#  Clock tree
#      50 MHz board oscillator (K14, port clk)
#          +-> PLL u_pll (EG_PHY_PLL, al_ip/pll_m1_hdmi, VCO = 1000 MHz)
#                +-> clkc[1] =  25.000 MHz  pixel clock  (period 40.000 ns)
#                +-> clkc[2] = 125.000 MHz  serial clock (period  8.000 ns)
#          +-> Sdram_Control_4Port / Sdram_PLL (EG_PHY_PLL, VCO = 1000 MHz)
#                +-> clkc[0] = 100.000 MHz  SDRAM controller / WR1 clock
#                +-> clkc[1] = 100.000 MHz, 270 deg  SDRAM macro clock
#          +-> reset synchronisers
#
#  The PLLs are plain Verilog files in this project, so TD sees the EG_PHY_PLL
#  macros as pass-throughs of clk_50m and rejects a second primary
#  create_clock on their outputs ("primary clock ... is on the network of
#  clock clk_50m").  create_generated_clock is the correct SDC construct here;
#  the resulting periods are exactly 40 / 8 / 10 ns.
#
#  Clocks are referenced through PLL instance pins (structural names owned by
#  this project) and NOT through synthesised net names like the vendor board
#  test did (get_nets {S_pixel_clk}).
#
#  set_clock_groups -exclusive
#    * pixel_clk <-> serial_clk : the 10 bit TMDS word is handed to the shift
#      register by the self-timed load pulse of lane_lvds_10_1.
#    * pixel_clk <-> sdram_clk  : every crossing goes through the 512 word
#      asynchronous FIFOs of Sdram_Control_4Port, or is a quasi-static level
#      (page select / start toggle / done toggle) protected by 2 FF
#      synchronisers + edge detectors.
#    * clk_50m <-> all          : the 50 MHz domain only samples KEY2 and
#      produces the asynchronous reset release.
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

# 100.000 MHz SDRAM controller clock = 2 x 50.000 MHz
create_generated_clock -name sdram_clk \
    -source [get_ports {clk}] -multiply_by 2 \
    [get_pins {u_sdram/sdram_pll1/pll_inst.clkc[0]}]

# The 270 degree output only drives the clock pin of the in-die
# EG_PHY_SDRAM_2M_32 hard macro, so it is left unconstrained on purpose:
# there is no register-to-register path in that domain.

set_clock_groups -exclusive \
    -group [get_clocks {clk_50m}] \
    -group [get_clocks {pixel_clk}] \
    -group [get_clocks {serial_clk}] \
    -group [get_clocks {sdram_clk}]
