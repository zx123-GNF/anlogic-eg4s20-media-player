#-----------------------------------------------------------------------------
#  timing.sdc  --  M4 : M3 player + WM8960 audio (AC208 / EG4S20BG256)
#
#  M4 adds ONE clock domain: the WM8960 master clock
#
#      12.288136 MHz  mclk_audio   (period 81.379 ns)
#
#  produced by the third PLL (u_pll_audio, al_ip/pll_m4_audio, VCO 725 MHz,
#  CLKC0 divider 59).  It clocks only m4_sine_tone and m4_i2s_tx; the crossings
#  into it are one quasi-static level (init_ok, 2FF synchronised) and nothing
#  else.  The 40 kHz I2C engine runs in the existing 50 MHz domain.
#
#  How the clock is constrained (and why)
#  --------------------------------------
#  The PLLs in this project are plain Verilog files, so TD sees the EG_PHY_PLL
#  macros as pass-throughs of clk_50m and rejects a second primary
#  create_clock on their outputs ("primary clock ... is on the network of
#  clock clk_50m").  create_generated_clock is the correct construct (same
#  approach as M0/M1/M2/M3), and TD accepts only one of -divide_by /
#  -multiply_by per command (USR-8157).
#
#  The real ratio is 50/12.288136 = 4.069, i.e. NOT an integer, so it cannot be
#  expressed exactly.  Declaring -divide_by 4 tells STA the domain is 12.5 MHz
#  (80 ns) instead of 12.288 MHz (81.4 ns): 1.7 % pessimistic, which is the safe
#  direction, and it still gives the domain a real clock object so that its
#  internal paths are analysed and the cross domain paths are cut by the
#  -exclusive group below.
#
#  Clock tree
#      50 MHz board oscillator (K14, port clk)
#          +-> PLL u_pll (EG_PHY_PLL, al_ip/pll_m4_hdmi, VCO = 1000 MHz)
#                +-> clkc[1] =  25.000 MHz  pixel clock  (period 40.000 ns)
#                +-> clkc[2] = 125.000 MHz  serial clock (period  8.000 ns)
#          +-> PLL u_sdram/sdram_pll1 (inside Sdram_Control_4Port)
#                +-> clkc[0] = 100.000 MHz  SDRAM domain (SD SPI, FAT32, pixel)
#                +-> clkc[1] = 100.000 MHz, 270 deg  SDRAM macro clock
#          +-> PLL u_pll_audio (NEW in M4)
#                +-> clkc[0] =  12.288136 MHz  mclk_audio
#          +-> clk_div_var inside sd_card_control
#                +-> spi_clk  = 100 MHz / 125 = 0.8 MHz during card init
#                             = 100 MHz /   2 =  50 MHz during data transfer
#                  (spi_driver divides it by 2 again -> 400 kHz / 25 MHz SCLK)
#          +-> reset synchronisers, WM8960 I2C engine (40 kHz SCL)
#
#  set_clock_groups -exclusive
#    * pixel_clk <-> serial_clk : the 10 bit TMDS word is handed to the shift
#      register by the self-timed load pulse of lane_lvds_10_1.
#    * pixel_clk <-> sdram_clk  : every crossing goes through the 512 word
#      asynchronous FIFOs of Sdram_Control_4Port, or is a quasi-static level
#      (page select / ready toggle / key toggle) protected by 2 FF
#      synchronisers + edge detectors.
#    * mclk_audio <-> everything : the audio subsystem is a closed domain.  Its
#      only input is init_ok (quasi-static level, 2FF synchronised in m4_top);
#      the I2S pins are outputs.  Declaring the domain exclusive keeps the
#      50 MHz -> 12.29 MHz and 100 MHz -> 12.29 MHz paths out of STA, where a
#      real synchroniser makes the timing irrelevant.
#    * clk_50m <-> all          : the 50 MHz domain samples KEY2, runs the I2C
#      engine and produces the asynchronous reset releases.
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

#-----------------------------------------------------------------------------
#  NEW in M4 : WM8960 MCLK domain = 12.288136 MHz
#  (declared as 50/4 = 12.5 MHz, 1.7 % pessimistic, see the note above)
#-----------------------------------------------------------------------------
create_generated_clock -name mclk_audio \
    -source [get_ports {clk}] -divide_by 4 \
    [get_pins {u_pll_audio/pll_inst.clkc[0]}]

# The 270 degree output only drives the clock pin of the in-die
# EG_PHY_SDRAM_2M_32 hard macro, so it is left unconstrained on purpose:
# there is no register-to-register path in that domain.

# The five clocks above are the whole constrained design.  The SD engine's SPI
# shift clock (clk_div_var inside sd_card_control, /125 = 0.8 MHz during init,
# /2 = 50 MHz during a transfer) is NOT constrained: its net is a mux output
# inside the flattened vendor hierarchy, so neither get_pins nor get_nets can
# address it (verified with a probe script - "No pins matched" /
# "get_nets *clk_out*" is empty).  Every command that references it fails with
# USR-6001 / USR-8159, and a failing set_clock_groups would drop the exclusive
# grouping for the other clocks, so the spi_clk constraint is deliberately
# left out.  Consequences and mitigations are listed in m2-report.md
# (risk R1): TD then reports no clock for those registers, no cross-domain
# path is analysed, and the endpoints of the five listed clocks are 0
# violated.

set_clock_groups -exclusive \
    -group [get_clocks {clk_50m}] \
    -group [get_clocks {pixel_clk}] \
    -group [get_clocks {serial_clk}] \
    -group [get_clocks {sdram_clk}] \
    -group [get_clocks {mclk_audio}]
