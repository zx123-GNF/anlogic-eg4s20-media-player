//=============================================================================
//  m0_top.v  --  M0 milestone: HDMI 640x480 colour bar output
//
//  Board  : AC208  (EG4S20BG256, Anlogic SALEAGLE 4)
//  Tool   : Anlogic TD 2026.1 SP2  (command-line flow, see run_flow.tcl)
//
//  Ports
//      clk          50 MHz board oscillator          K14  (LVCMOS33)
//      rst_n        KEY2, active low                 H14  (LVCMOS33)
//      O_tmds_*_p   HDMI TMDS clock / data pairs     B10 D11 C11 F10
//                   (differential, IOSTANDARD = LVDS33_E, N side is
//                    paired automatically by the place & route tool)
//
//  Chain
//      50 MHz --> pll_m0_hdmi --> 25.000 MHz pixel clock
//                                 125.000 MHz serial clock (10:1)
//      25 MHz  --> video_gen (AXIS master, 8 colour bars, RGB888)
//               --> hdmi_1_4b_transmitter_core_wrapper (encrypted IP)
//               --> hdmi_phy_wrapper (4 x lane_lvds_10_1, ODDR serializer)
//               --> TMDS pins
//
//  Only the HDMI chain is instantiated: no ethernet / camera / RTC / IR /
//  7-segment / SDRAM / audio logic from the vendor board test is present.
//=============================================================================
`timescale 1ns / 10ps

module m0_top (
    input  wire clk,            // 50 MHz, K14
    input  wire rst_n,          // KEY2, H14, low active

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
    // clocks / reset
    //-------------------------------------------------------------------------
    wire S_pixel_clk;       // 25.000 MHz
    wire S_serial_clk;      // 125.000 MHz
    wire S_pll_lock;
    wire S_clk100_unused;

    pll_m0_hdmi u_pll (
        .refclk  (clk),
        .reset   (1'b0),
        .extlock (S_pll_lock),
        .clk0_out(S_clk100_unused),
        .clk1_out(S_pixel_clk),
        .clk2_out(S_serial_clk)
    );

    //-------------------------------------------------------------------------
    // Reset
    //   KEY2 is asynchronous -> sample it on the 50 MHz reference clock.
    //   The resulting S_rst_n_async is then released synchronously inside each
    //   PLL clock domain (async assert / sync release), so no flop sees a
    //   recovery/removal hazard from another clock domain.
    //-------------------------------------------------------------------------
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
    // AXIS video source (colour bars)
    //-------------------------------------------------------------------------
    wire        S_axis_user;
    wire        S_axis_valid;
    wire        S_axis_last;
    wire [23:0] S_axis_data;
    wire        S_axis_ready;

    video_gen #(
        .HTOTAL (HTOTAL),
        .HSA    (HSA),
        .HBP    (HBP),
        .HFP    (HFP),
        .HACTIVE(HACTIVE),
        .VTOTAL (VTOTAL),
        .VSA    (VSA),
        .VBP    (VBP),
        .VFP    (VFP),
        .VACTIVE(VACTIVE)
    ) u_video_gen (
        .I_clk        (S_pixel_clk),
        .I_rst        (S_rst_pixel),
        .O_video_user (S_axis_user),
        .O_video_valid(S_axis_valid),
        .O_video_last (S_axis_last),
        .O_video_data (S_axis_data),
        .I_video_ready(S_axis_ready)
    );

    //-------------------------------------------------------------------------
    // HDMI 1.4b transmitter core (encrypted IP, vendor supplied)
    //   VIDEO_TPG must be "Disable", otherwise the internal test pattern
    //   generator overrides I_axis_s_data.
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

        .AUDIO_SAMPLE_RATE ("48K"),     // audio unused in M0
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
    // TMDS serializers (4 lanes, ODDR based 10:1)
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
