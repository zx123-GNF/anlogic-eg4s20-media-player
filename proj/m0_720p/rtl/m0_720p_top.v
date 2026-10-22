//=============================================================================
//  m0_720p_top.v
//  HDMI probe: 1280x720 @ 73.333 MHz pixel clock (59.26 Hz), colour bars.
//
//  WHY THIS PROJECT EXISTS
//  -----------------------
//  Our 640x480 design (25.000 MHz pixel clock, 59.52 Hz) makes the monitor
//  report "not support".  The monitor *does* decode the TMDS stream (otherwise
//  it would show "No Signal"), so the PLL / serializer / HDMI core are alive --
//  the monitor simply refuses that video mode.
//
//  The vendor board_test HDMI demo runs 1280x720 with a 73.333 MHz pixel clock
//  and 366.667 MHz serial clock (vendor IP pll_hdmi1_4b), so this project
//  reproduces exactly that clocking with our own AXIS colour-bar source:
//      pll_hdmi_720p  : 50 MHz -> 100 / 73.333 / 366.667 MHz (90 deg serial)
//      video_gen720   : 1650 x 750 total, 1280 x 720 active, 8 colour bars
//      hdmi core      : VIDEO_VIC = 4 (CEA 720p60), TPG disabled
//      hdmi_phy       : 4 x 10:1 ODDR serialisers
//
//  If the monitor shows the bars with this bit, our video path is fine at 720p
//  and the real player just has to render the 640x480 BMP inside a 720p canvas.
//=============================================================================
`timescale 1ns / 10ps

module m0_720p_top (
    input  wire clk,            // 50 MHz, K14
    input  wire rst_n,          // KEY2, H14, low active

    output wire O_tmds_ch0_p,   // D11 / D12
    output wire O_tmds_ch1_p,   // C11 / A11
    output wire O_tmds_ch2_p,   // F10 / H11
    output wire O_tmds_clk_p    // B10 / C9
);

    //-------------------------------------------------------------------------
    // 1280 x 720 @ 59.26 Hz (73.333 MHz pixel clock, 1650 x 750 total)
    //-------------------------------------------------------------------------
    localparam HTOTAL  = 1650;
    localparam HSA     = 40;
    localparam HFP     = 110;
    localparam HBP     = 220;
    localparam HACTIVE = 1280;

    localparam VTOTAL  = 750;
    localparam VSA     = 5;
    localparam VFP     = 5;
    localparam VBP     = 20;
    localparam VACTIVE = 720;

    //-------------------------------------------------------------------------
    // clocks / reset
    //-------------------------------------------------------------------------
    wire S_pixel_clk;       //  73.333 MHz
    wire S_serial_clk;      // 366.667 MHz
    wire S_pll_lock;
    wire S_clk0_unused;     // 100.000 MHz (feedback tap)

    pll_hdmi_720p u_pll (
        .refclk  (clk),
        .reset   (1'b0),
        .extlock (S_pll_lock),
        .clk0_out(S_clk0_unused),
        .clk1_out(S_pixel_clk),
        .clk2_out(S_serial_clk)
    );

    reg [1:0] S_key_n_sync;
    always @(posedge clk) begin
        S_key_n_sync <= {S_key_n_sync[0], rst_n};
    end

    wire S_rst_n_async = S_pll_lock & S_key_n_sync[1];

    reg [1:0] S_rst_pix_sync;
    always @(posedge S_pixel_clk or negedge S_rst_n_async) begin
        if (!S_rst_n_async)
            S_rst_pix_sync <= 2'b00;
        else
            S_rst_pix_sync <= {S_rst_pix_sync[0], 1'b1};
    end
    wire S_rst_pixel = ~S_rst_pix_sync[1];

    reg [1:0] S_rst_ser_sync;
    always @(posedge S_serial_clk or negedge S_rst_n_async) begin
        if (!S_rst_n_async)
            S_rst_ser_sync <= 2'b00;
        else
            S_rst_ser_sync <= {S_rst_ser_sync[0], 1'b1};
    end
    wire S_rst_serial = ~S_rst_ser_sync[1];

    //-------------------------------------------------------------------------
    // AXIS video source (colour bars, 1280 x 720)
    //-------------------------------------------------------------------------
    wire        S_axis_user;
    wire        S_axis_valid;
    wire        S_axis_last;
    wire [23:0] S_axis_data;
    wire        S_axis_ready;

    video_gen720 #(
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

        .VIDEO_VIC         (4),         // CEA-861 1280x720p @ 60 Hz
        .VIDEO_TPG         ("Disable"), // external AXIS stream only
        .VIDEO_FORMAT      ("RGB"),

        .AUDIO_SAMPLE_RATE ("48K"),
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
