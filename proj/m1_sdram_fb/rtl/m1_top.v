//=============================================================================
//  m1_top.v  --  M1 milestone: in-die SDRAM frame buffer -> HDMI
//
//  Board  : AC208  (EG4S20BG256, Anlogic SALEAGLE 4)
//  Tool   : Anlogic TD 2026.1 SP2  (command line flow, see run_flow.tcl)
//
//  Ports
//      clk          50 MHz board oscillator          K14  (LVCMOS33)
//      rst_n        KEY2, active low                 H14  (LVCMOS33)
//      key0_n       KEY0, active low, page swap      F7   (LVCMOS33)
//      O_tmds_*_p   HDMI TMDS clock / data pairs     B10 D11 C11 F10
//
//  Chain
//      50 MHz --> pll_m1_hdmi --> 25.000 MHz pixel clock
//                                 125.000 MHz serial clock (10:1)
//      50 MHz --> Sdram_Control_4Port
//                    +-- internal Sdram_PLL --> 100 MHz controller clock
//                    +-- EG_PHY_SDRAM_2M_32 (in-die 2M x 32 = 8 MB hard macro)
//      pixel domain  : raster generator + page control  --> WR1 start/page
//      100 MHz domain: test pattern writer               --> WR1 (page A / B)
//                    : SDRAM read port RD1 (page A) \
//                    : SDRAM read port RD2 (page B)  > 512 word async FIFOs
//      pixel domain  : one word per active pixel from RD1/RD2, page mux
//                    --> AXIS 640x480 RGB888 --> HDMI 1.4b core --> TMDS
//
//  Double buffering
//      page A / page B alternate; the writer always fills the page that is
//      not on screen and the display page is switched at the frame tick
//      (vertical blanking).  See m1_video_src.v for the page FSM.
//=============================================================================
`timescale 1ns / 10ps

module m1_top (
    input  wire clk,            // 50 MHz, K14
    input  wire rst_n,          // KEY2, H14, low active
    input  wire key0_n,         // KEY0, F7, low active, manual page swap

    output wire O_tmds_ch0_p,   // D11 / D12
    output wire O_tmds_ch1_p,   // C11 / A11
    output wire O_tmds_ch2_p,   // F10 / H11
    output wire O_tmds_clk_p    // B10 / C9
);

    //-------------------------------------------------------------------------
    // 640 x 480 @ 59.52 Hz (25.000 MHz pixel clock, 800 x 525 total)
    //-------------------------------------------------------------------------
    localparam HTOTAL  = 800;
    localparam HSA     = 96;
    localparam HFP     = 16;
    localparam HBP     = 48;
    localparam HACTIVE = 640;

    localparam VTOTAL  = 525;
    localparam VSA     = 2;
    localparam VFP     = 10;
    localparam VBP     = 33;
    localparam VACTIVE = 480;

    //-------------------------------------------------------------------------
    // frame buffer geometry (SDRAM addresses are 32 bit WORD addresses)
    //   one pixel = one word, low 24 bit = RGB888
    //   one page   = 640*480 = 307200 words = 0x4B000 words = 0x12C000 bytes
    //-------------------------------------------------------------------------
    localparam [20:0] PAGE_A_BASE = 21'h000000;             //   0 W, 0x000000 B
    localparam [20:0] PAGE_B_BASE = 21'h04B000;             // 307200 W, 0x12C000 B
    localparam [20:0] PAGE_A_END  = 21'h04B000;             // 307200 words
    localparam [20:0] PAGE_END    = 21'h096000;             // 614400 words

    //-------------------------------------------------------------------------
    // clocks / reset
    //-------------------------------------------------------------------------
    wire S_pixel_clk;       // 25.000 MHz
    wire S_serial_clk;      // 125.000 MHz
    wire S_pll_lock;
    wire S_clk100_unused;

    pll_m1_hdmi u_pll (
        .refclk  (clk),
        .reset   (1'b0),
        .extlock (S_pll_lock),
        .clk0_out(S_clk100_unused),
        .clk1_out(S_pixel_clk),
        .clk2_out(S_serial_clk)
    );

    // KEY2 is asynchronous -> sample it on the 50 MHz reference clock.
    reg [1:0] S_key_n_sync;
    always @(posedge clk) begin
        S_key_n_sync <= {S_key_n_sync[0], rst_n};
    end

    wire S_rst_n_async = S_pll_lock & S_key_n_sync[1];

    // pixel clock domain (25 MHz) : video source + HDMI core
    reg [1:0] S_rst_pix_sync;
    always @(posedge S_pixel_clk or negedge S_rst_n_async) begin
        if (!S_rst_n_async)
            S_rst_pix_sync <= 2'b00;
        else
            S_rst_pix_sync <= {S_rst_pix_sync[0], 1'b1};
    end
    wire S_rst_pixel = ~S_rst_pix_sync[1];

    // serial clock domain (125 MHz) : TMDS serialisers
    reg [1:0] S_rst_ser_sync;
    always @(posedge S_serial_clk or negedge S_rst_n_async) begin
        if (!S_rst_n_async)
            S_rst_ser_sync <= 2'b00;
        else
            S_rst_ser_sync <= {S_rst_ser_sync[0], 1'b1};
    end
    wire S_rst_serial = ~S_rst_ser_sync[1];

    //-------------------------------------------------------------------------
    // SDRAM controller
    //-------------------------------------------------------------------------
    wire        S_sdram_clk;        // 100 MHz, CLK output of the controller
    wire        S_sdr_clk;          // 100 MHz 270 deg, to the SDRAM macro
    wire [10:0] S_sa;
    wire [1:0]  S_ba;
    wire [1:0]  S_cs_n;             // both chip selects are driven together
    wire        S_cke, S_ras_n, S_cas_n, S_we_n;
    wire [31:0] S_dq;
    wire [3:0]  S_dqm;
    wire        S_test_oe_unused;

    wire [31:0] S_wr_data;
    wire        S_wr;
    wire        S_wr_full;
    wire [31:0] S_rd1_data;
    wire [31:0] S_rd2_data;
    wire        S_rd1_re, S_rd2_re;
    wire        S_rd1_empty, S_rd2_empty;

    // The controller is kept in reset ~1.3 ms after the HDMI PLL locks so the
    // internal Sdram_PLL (100 MHz) is comfortably locked as well; the release
    // is synchronised inside the 100 MHz domain.
    reg [15:0] S_sdram_rst_cnt;
    always @(posedge S_pixel_clk or negedge S_rst_n_async) begin
        if (!S_rst_n_async)
            S_sdram_rst_cnt <= 16'd0;
        else if (!S_sdram_rst_cnt[15])
            S_sdram_rst_cnt <= S_sdram_rst_cnt + 16'd1;
    end
    wire S_sdram_rst_n_pix = S_sdram_rst_cnt[15];

    reg [1:0] S_sdram_rst_sync;
    always @(posedge S_sdram_clk or negedge S_sdram_rst_n_pix) begin
        if (!S_sdram_rst_n_pix)
            S_sdram_rst_sync <= 2'b00;
        else
            S_sdram_rst_sync <= {S_sdram_rst_sync[0], 1'b1};
    end
    wire S_sdram_ready = S_sdram_rst_sync[1];
    wire S_rst_sdram   = ~S_sdram_ready;

    Sdram_Control_4Port u_sdram (
        // host side
        .REF_CLK      (clk),
        .RESET_N      (~S_rst_sdram),
        .CLK          (S_sdram_clk),

        // FIFO write side 1 : test pattern, ring over page A + page B
        .WR1_DATA     (S_wr_data),
        .WR1          (S_wr),
        .WR1_ADDR     (PAGE_A_BASE),
        .WR1_MAX_ADDR (PAGE_END),
        .WR1_LENGTH   (9'h80),
        .WR1_LOAD     (1'b0),          // address counter free runs as a ring
        .WR1_CLK      (S_sdram_clk),
        .WR1_FULL     (S_wr_full),
        .WR1_USE      (),

        // FIFO write side 2 : unused
        .WR2_DATA     (32'd0),
        .WR2         (1'b0),
        .WR2_ADDR     (21'd0),
        .WR2_MAX_ADDR (21'd0),
        .WR2_LENGTH   (9'd0),
        .WR2_LOAD     (1'b0),
        .WR2_CLK      (1'b0),
        .WR2_FULL     (),
        .WR2_USE      (),

        // FIFO read side 1 : page A
        .RD1_DATA     (S_rd1_data),
        .RD1          (S_rd1_re),
        .RD1_ADDR     (PAGE_A_BASE),
        .RD1_MAX_ADDR (PAGE_A_END),
        .RD1_LENGTH   (9'h80),
        .RD1_LOAD     (1'b0),          // loaded by RESET_N, then free runs
        .RD1_CLK      (S_pixel_clk),
        .RD1_EMPTY    (S_rd1_empty),
        .RD1_USE      (),

        // FIFO read side 2 : page B
        .RD2_DATA     (S_rd2_data),
        .RD2          (S_rd2_re),
        .RD2_ADDR     (PAGE_B_BASE),
        .RD2_MAX_ADDR (PAGE_END),
        .RD2_LENGTH   (9'h80),
        .RD2_LOAD     (1'b0),
        .RD2_CLK      (S_pixel_clk),
        .RD2_EMPTY    (S_rd2_empty),
        .RD2_USE      (),

        // SDRAM side (all of it stays inside the die)
        .SA           (S_sa),
        .BA           (S_ba),
        .CS_N         (S_cs_n),
        .CKE          (S_cke),
        .RAS_N        (S_ras_n),
        .CAS_N        (S_cas_n),
        .WE_N         (S_we_n),
        .DQ           (S_dq),
        .DQM          (S_dqm),
        .SDR_CLK      (S_sdr_clk),
        .test_oe      (S_test_oe_unused)
    );

    sdram_ip u_sdram_mem (
        .clk   (S_sdr_clk),
        .ras_n (S_ras_n),
        .cas_n (S_cas_n),
        .we_n  (S_we_n),
        .addr  (S_sa),
        .ba    (S_ba),
        .dq    (S_dq),
        .cs_n  (S_cs_n[0]),
        .dm0   (S_dqm[0]),
        .dm1   (S_dqm[1]),
        .dm2   (S_dqm[2]),
        .dm3   (S_dqm[3]),
        .cke   (S_cke)
    );

    //-------------------------------------------------------------------------
    // AXIS video source : SDRAM page read-out + double buffer page control
    //-------------------------------------------------------------------------
    wire        S_axis_user;
    wire        S_axis_valid;
    wire        S_axis_last;
    wire [23:0] S_axis_data;
    wire        S_axis_ready;

    wire        S_wr_start_tog;
    wire        S_wr_page;
    wire        S_wr_done_tog;

    m1_video_src #(
        .HTOTAL  (HTOTAL),
        .HSA     (HSA),
        .HBP     (HBP),
        .HFP     (HFP),
        .HACTIVE (HACTIVE),
        .VTOTAL  (VTOTAL),
        .VSA     (VSA),
        .VBP     (VBP),
        .VFP     (VFP),
        .VACTIVE (VACTIVE)
    ) u_video_src (
        .I_clk          (S_pixel_clk),
        .I_rst          (S_rst_pixel),
        .I_key0_n       (key0_n),
        .I_sdram_ready  (S_sdram_ready),
        .I_rd1_data     (S_rd1_data),
        .I_rd2_data     (S_rd2_data),
        .O_rd1_re       (S_rd1_re),
        .O_rd2_re       (S_rd2_re),
        .O_wr_start_tog (S_wr_start_tog),
        .O_wr_page      (S_wr_page),
        .I_wr_done_tog  (S_wr_done_tog),
        .O_video_user   (S_axis_user),
        .O_video_valid  (S_axis_valid),
        .O_video_last   (S_axis_last),
        .O_video_data   (S_axis_data)
    );

    m1_sdram_wr #(
        .HACTIVE (HACTIVE),
        .VACTIVE (VACTIVE)
    ) u_sdram_wr (
        .I_clk       (S_sdram_clk),
        .I_rst       (S_rst_sdram),
        .I_start_tog (S_wr_start_tog),
        .I_page      (S_wr_page),
        .I_fifo_full (S_wr_full),
        .O_wr        (S_wr),
        .O_wr_data   (S_wr_data),
        .O_done_tog  (S_wr_done_tog)
    );

    //-------------------------------------------------------------------------
    // HDMI 1.4b transmitter core (encrypted IP, vendor supplied)
    //-------------------------------------------------------------------------
    wire [9:0] S_ch0_tmds_data;
    wire [9:0] S_ch1_tmds_data;
    wire [9:0] S_ch2_tmds_data;
    wire [9:0] S_clk_tmds_data;

    wire S_ddc_scl_unused;
    wire S_ddc_sda_unused;
    wire S_edid_valid_unused;
    wire [7:0] S_edid_data_unused;
    wire S_video_locked_unused;

    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE            ("EG"),

        .HTOTAL            (HTOTAL),
        .HSA               (HSA),
        .HFP               (HFP),
        .HBP               (HBP),
        .HACTIVE           (HACTIVE),
        .VTOTAL            (VTOTAL),
        .VSA               (VSA),
        .VFP               (VFP),
        .VBP               (VBP),
        .VACTIVE           (VACTIVE),

        .VIDEO_VIC         (1),         // 640x480p @ 60 Hz
        .VIDEO_TPG         ("Disable"), // external AXIS stream only
        .VIDEO_FORMAT      ("RGB"),

        .AUDIO_SAMPLE_RATE ("48K"),     // audio unused in M1
        .IIC_SCL_DIV       (125)
    ) u_hdmi_core (
        .I_pixel_clk        (S_pixel_clk),
        .I_rst              (S_rst_pixel),

        .I_edid_read_trig   (1'b0),
        .O_edid_read_valid  (S_edid_valid_unused),
        .O_edid_read_data   (S_edid_data_unused),

        .I_axis_s_user      (S_axis_user),
        .I_axis_s_valid     (S_axis_valid),
        .I_axis_s_last      (S_axis_last),
        .I_axis_s_data      (S_axis_data),
        .O_axis_s_ready     (S_axis_ready),

        .I_audio_valid      (1'b0),
        .I_audio_left_data  (24'd0),
        .I_audio_right_data (24'd0),

        .I_acr_valid        (1'b0),
        .I_acr_cts          (20'd0),
        .I_acr_n            (20'd0),

        .O_video_locked     (S_video_locked_unused),

        .O_ddc_scl          (S_ddc_scl_unused),
        .IO_ddc_sda         (S_ddc_sda_unused),

        .O_ch0_tmds_data    (S_ch0_tmds_data),
        .O_ch1_tmds_data    (S_ch1_tmds_data),
        .O_ch2_tmds_data    (S_ch2_tmds_data),
        .O_clk_tmds_data    (S_clk_tmds_data)
    );

    //-------------------------------------------------------------------------
    // TMDS serialisers (4 lanes, ODDR based 10:1)
    //-------------------------------------------------------------------------
    hdmi_phy_wrapper #(
        .DEVICE ("EG")
    ) u_hdmi_phy (
        .I_pixel_clk        (S_pixel_clk),
        .I_serial_clk       (S_serial_clk),
        .I_rst              (S_rst_serial),

        .I_tmds_channel_0   (S_ch0_tmds_data),
        .I_tmds_channel_1   (S_ch1_tmds_data),
        .I_tmds_channel_2   (S_ch2_tmds_data),
        .I_tmds_channel_clk (S_clk_tmds_data),

        .O_tmds_ch0_p       (O_tmds_ch0_p),
        .O_tmds_ch1_p       (O_tmds_ch1_p),
        .O_tmds_ch2_p       (O_tmds_ch2_p),
        .O_tmds_clk_p       (O_tmds_clk_p)
    );

endmodule
