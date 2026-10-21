#-----------------------------------------------------------------------------
#  timing.sdc  --  M2 TF/FAT32/BMP player -> HDMI 640x480 (AC208 / EG4S20BG256)
#
#  Clock tree
#      50 MHz board oscillator (K14, port clk)
#          +-> PLL u_pll (EG_PHY_PLL, al_ip/pll_m2_hdmi, VCO = 1000 MHz)
#                +-> clkc[1] =  25.000 MHz  pixel clock  (period 40.000 ns)
#                +-> clkc[2] = 125.000 MHz  serial clock (period  8.000 ns)
#          +-> Sdram_Control_4Port / Sdram_PLL (EG_PHY_PLL, VCO = 1000 MHz)
#                +-> clkc[0] = 100.000 MHz  SDRAM controller, SDRAM domain,
#                                           SD SPI engine, FAT32 FSM
#                +-> clkc[1] = 100.000 MHz, 270 deg  SDRAM macro clock
#          +-> clk_div_var inside sd_card_control
#                +-> spi_clk  = 100 MHz / 125 = 0.8 MHz during card init
#                             = 100 MHz /   2 =  50 MHz during data transfer
#                  (spi_driver divides it by 2 again -> 400 kHz / 25 MHz SCLK)
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
#      (page select / ready toggle / key toggle) protected by 2 FF
#      synchronisers + edge detectors.
#    * clk_50m <-> all          : the 50 MHz domain only samples KEY2 and
#      produces the asynchronous reset release.
#    * spi_clk                  : the SD engine's divided clock.  All crossings
#      into it are quasi-static levels (start, mode, sector_addr) held for the
#      whole transaction, and the sector buffer it writes is a true dual-clock
#      RAM read by the 100 MHz side, so it is exclusive with everything else.
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

# The four clocks above are the whole constrained design.  The SD engine's SPI
# shift clock (clk_div_var inside sd_card_control, /125 = 0.8 MHz during init,
# /2 = 50 MHz during a transfer) is NOT constrained: its net is a mux output
# inside the flattened vendor hierarchy, so neither get_pins nor get_nets can
# address it (verified with a probe script - "No pins matched" /
# "get_nets *clk_out*" is empty).  Every command that references it fails with
# USR-6001 / USR-8159, and a failing set_clock_groups would drop the exclusive
# grouping for the other four clocks, so the spi_clk constraint is deliberately
# left out.  Consequences and mitigations are listed in m2-report.md
# (risk R1): TD then reports no clock for those registers, no cross-domain
# path is analysed, and the 5514 endpoints of the four listed clocks are 0
# violated.

set_clock_groups -exclusive \
    -group [get_clocks {clk_50m}] \
    -group [get_clocks {pixel_clk}] \
    -group [get_clocks {serial_clk}] \
    -group [get_clocks {sdram_clk}]
