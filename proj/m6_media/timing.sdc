#-----------------------------------------------------------------------------
#  timing.sdc  --  m6_media  (photo + video playlist player, 1280x720 HDMI output)
#
#  Clock tree
#      50 MHz board oscillator (K14, port clk)
#          +-> PLL u_pll (vendor pll_hdmi1_4b, copied as pll_hdmi_720p)
#                +-> clkc[0] = 100.000 MHz   feedback tap (no logic)
#                +-> clkc[1] =  73.333 MHz   pixel clock  (period 13.635 ns)
#                +-> clkc[2] = 366.667 MHz   serial clock (  2.727 ns, 90 deg)
#          +-> Sdram_Control_4Port / Sdram_PLL (vendor, VCO = 1000 MHz)
#                +-> clkc[0] = 100.000 MHz  SDRAM controller, SD SPI engine,
#                                           FAT32 FSM, page writer
#                +-> clkc[1] = 100.000 MHz, 270 deg  in-die SDRAM macro clock
#
#  TD rejects -divide_by together with -multiply_by in one command
#  (USR-8157/USR-8159), so the 1100 MHz VCO is declared first on the unused
#  C0 tap and the two real clocks are derived from it one step at a time.
#  This construction was validated on the m0_720p probe build (all clocks
#  defined, serial domain SWNS = +0.691 ns).
#-----------------------------------------------------------------------------

create_clock -name clk_50m -period 20.000 -waveform {0 10.000} [get_ports {clk}]

# 50 * 22 = 1100 MHz VCO reference on the (logic-unused) C0 tap
create_generated_clock -name clk_vco -source [get_ports {clk}] -multiply_by 22 \
    [get_pins {u_pll/pll_inst.clkc[0]}]

# 1100 / 15 = 73.333 MHz pixel clock
create_generated_clock -name pixel_clk -source [get_pins {u_pll/pll_inst.clkc[0]}] \
    -divide_by 15 \
    [get_pins {u_pll/pll_inst.clkc[1]}]

# 1100 / 3 = 366.667 MHz serial clock (10:1 TMDS with a DDR output)
create_generated_clock -name serial_clk -source [get_pins {u_pll/pll_inst.clkc[0]}] \
    -divide_by 3 \
    [get_pins {u_pll/pll_inst.clkc[2]}]

# 100.000 MHz SDRAM controller clock = 2 x 50.000 MHz
create_generated_clock -name sdram_clk \
    -source [get_ports {clk}] -multiply_by 2 \
    [get_pins {u_sdram/sdram_pll1/pll_inst.clkc[0]}]


#-----------------------------------------------------------------------------
#  M6 has no audio PLL: M4/M5 drove a WM8960 over I2S from a third PLL
#  (12.288 MHz), but the delivered audio path is HDMI embedded audio, whose
#  sample strobe is derived from the pixel clock inside m6_top.  The M6 build
#  therefore instantiates only the HDMI PLL and the SDRAM PLL.
#-----------------------------------------------------------------------------
# The 270 degree SDRAM macro clock only drives the hard macro clock pin (no
# register-to-register paths), and the SD engine's divided SPI shift clock is a
# mux output inside the flattened vendor hierarchy that cannot be addressed by
# get_pins/get_nets (see m2-report.md risk R1); both are left unconstrained.

set_clock_groups -exclusive -group [get_clocks {clk_50m}] -group [get_clocks {pixel_clk}] -group [get_clocks {serial_clk}] -group [get_clocks {sdram_clk}]