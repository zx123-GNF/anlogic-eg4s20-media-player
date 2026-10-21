/************************************************************\
 **  pll_m4_audio.v  --  M4 audio PLL : 50 MHz -> 12.2881 MHz WM8960 MCLK
 **
 **  Hand written EG_PHY_PLL instantiation in exactly the style of
 **  al_ip/pll_m4_hdmi/pll_m4_hdmi.v (M0/M1/M2/M3) and of the vendor file
 **  src/5640/sdram_ctrl_4p/Sdram_PLL.v.  No IP generator was used, because TD
 **  has no scriptable IP generator (see docs/research/m0-report.md section 7.1).
 **
 **  Why 725 MHz VCO and not 1000 MHz
 **  --------------------------------
 **  With internal feedback (FEEDBK_MODE = NOCOMP, FEEDBK_PATH = VCO_PHASE_0)
 **  every output frequency is
 **
 **        f_out = f_in * FBCLK_DIV / (REFCLK_DIV * CLKCn_DIV)
 **
 **  i.e. f_out = 50 MHz * M / (N * C) with integer M, N, C in 1..128.
 **  For f_out = 12.288 MHz this needs  M/(N*C) = 12.288/50 = 768/3125, and
 **  3125 = 5^5 does not divide 768 = 2^8*3, so C (or M) would have to be a
 **  multiple of 3125 -> f_vco = 12.288 MHz * 3125 = 38.4 GHz.  **Exact 12.288 MHz
 **  is therefore mathematically impossible from a 50 MHz reference with integer
 **  dividers** (this is the "VCO 1000 MHz cannot divide 12.288" note in the task).
 **
 **  Best rational approximation with small integers (continued fraction of
 **  0.24576 = 768/3125):
 **        1/4 = 0.25 -> 12.500 MHz (-1.7 %)
 **       14/57 = 0.245614 -> 12.2807 MHz (-0.06 %)
 **       29/118 = 0.245763 -> 12.28814 MHz (+0.0011 %, i.e. +11 ppm)   <-- used
 **
 **      29/118 = 29/(2*59):  M = 29, N = 2, C = 59
 **      f_vco = 50 * 29 / 2 = 725 MHz          (legal: VCO range 300..1200 MHz)
 **      f_out = 725 / 59     = 12.288136 MHz   (+11 ppm vs 12.288000 MHz)
 **      f_s   = f_out / 256  = 48.00053 kHz    (+11 ppm, inaudible)
 **
 **  The 11 ppm error is 20x smaller than the 50 MHz oscillator tolerance of a
 **  typical crystal (+-50 ppm), so the tone is "1 kHz" for every practical
 **  purpose.  See docs/research/m4-report.md section 4 for the full derivation,
 **  the rejected alternatives and the one-line fallback (VCO 1000 MHz, C = 81
 **  -> 12.3457 MHz, +0.47 %) if this VCO band does not lock on the board.
 **
 **  Loop filter
 **  -----------
 **  GMC_GAIN / ICP_CURRENT / KVCO / LPF_CAPACITOR / LPF_RESISTOR are copied from
 **  the vendor Sdram_PLL.v (same device, VCO 1000 MHz, PFD 50 MHz, "Medium"
 **  bandwidth in the IP generator).  This design runs VCO 725 MHz / PFD 25 MHz,
 **  i.e. both about half, which moves the loop bandwidth down (slower lock, more
 **  stable) - the conservative direction.  Not verified on silicon; see risk
 **  M4-R1 in the report.
 **
 **  Outputs
 **  -------
 **      clk0_out = 12.288136 MHz   WM8960 MCLK (also the M4 audio clock domain)
 **      clk1..4  = disabled
 \************************************************************/
`timescale 1 ns / 100 fs

module pll_m4_audio (
    refclk,
    reset,
    extlock,
    clk0_out
);

    input  wire refclk;     // 50 MHz board oscillator
    input  wire reset;      // tied to 1'b0 by the top level
    output wire extlock;    // PLL lock, high = locked
    output wire clk0_out;   // 12.288136 MHz audio master clock

    wire S_unused_c1;
    wire S_unused_c2;
    wire S_unused_c3;
    wire S_unused_c4;
    wire S_unused_psdone;
    wire [7:0] S_unused_do;

    EG_PHY_PLL #(
        .DPHASE_SOURCE      ("DISABLE"),
        .DYNCFG             ("DISABLE"),
        .FIN                ("50.000000"),
        .FEEDBK_MODE        ("NOCOMP"),
        .FEEDBK_PATH        ("VCO_PHASE_0"),
        .STDBY_ENABLE       ("DISABLE"),
        .PLLRST_ENA         ("ENABLE"),
        .SYNC_ENABLE        ("DISABLE"),
        // loop filter: same values as the vendor Sdram_PLL.v (VCO 1000/PFD 50)
        .GMC_GAIN           (4),
        .ICP_CURRENT        (13),
        .KVCO               (4),
        .LPF_CAPACITOR      (1),
        .LPF_RESISTOR       (4),
        // VCO = 50 MHz * 29 / 2 = 725 MHz
        .REFCLK_DIV         (2),
        .FBCLK_DIV          (29),
        // CLKC0 = 725 / 59 = 12.288136 MHz  (CPHASE = DIV-1, FPHASE = 0 -> 0 deg)
        .CLKC0_ENABLE       ("ENABLE"),
        .CLKC0_DIV          (59),
        .CLKC0_CPHASE       (58),
        .CLKC0_FPHASE       (0),
        .CLKC1_ENABLE       ("DISABLE"),
        .CLKC1_DIV          (1),
        .CLKC1_CPHASE       (1),
        .CLKC1_FPHASE       (0),
        .CLKC2_ENABLE       ("DISABLE"),
        .CLKC2_DIV          (1),
        .CLKC2_CPHASE       (1),
        .CLKC2_FPHASE       (0),
        .CLKC3_ENABLE       ("DISABLE"),
        .CLKC3_DIV          (1),
        .CLKC3_CPHASE       (1),
        .CLKC3_FPHASE       (0),
        .CLKC4_ENABLE       ("DISABLE"),
        .CLKC4_DIV          (1),
        .CLKC4_CPHASE       (1),
        .CLKC4_FPHASE       (0)
    ) pll_inst (
        .refclk     (refclk),
        .reset      (reset),
        .stdby      (1'b0),
        .extlock    (extlock),
        .load_reg   (1'b0),
        .psclk      (1'b0),
        .psdown     (1'b0),
        .psstep     (1'b0),
        .psclksel   (3'b000),
        .psdone     (S_unused_psdone),
        .dclk       (1'b0),
        .dcs        (1'b0),
        .dwe        (1'b0),
        .di         (8'b00000000),
        .daddr      (6'b000000),
        .do         (S_unused_do),
        .fbclk      (1'b0),
        .clkc       ({S_unused_c4, S_unused_c3, S_unused_c2, S_unused_c1, clk0_out})
    );

endmodule
