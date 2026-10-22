//=============================================================================
//  video_gen720.v
//  Probe video source: 1280x720 colour bars (7.5 % grey-frame style is not used,
//  plain 8 bars like M0).  This is the 720p counterpart of m0_hdmi/rtl/video_gen.v
//  and only exists to find out whether the monitor accepts a 1280x720 mode at the
//  vendor's 73.333 MHz pixel clock (the same clock the vendor board_test TPG uses).
//
//  Differences from video_gen.v:
//    * H counters are 11 bit (HTOTAL = 1650 > 1023)
//    * active X is 11 bit (HACTIVE = 1280)
//    * vertical counters stay 10 bit (VTOTAL = 750)
//=============================================================================
`timescale 1ns / 10ps

module video_gen720 #(
    parameter HTOTAL  = 1650,
    parameter HSA     = 40,
    parameter HBP     = 220,
    parameter HFP     = 110,
    parameter HACTIVE = 1280,

    parameter VTOTAL  = 750,
    parameter VSA     = 5,
    parameter VBP     = 20,
    parameter VFP     = 5,
    parameter VACTIVE = 720
) (
    input  wire        I_clk,           // 73.333 MHz pixel clock
    input  wire        I_rst,           // active high

    output reg         O_video_user,
    output reg         O_video_valid,
    output reg         O_video_last,
    output reg  [23:0] O_video_data,
    input  wire        I_video_ready
);

    localparam HBLANK = HTOTAL - HACTIVE;   // 370
    localparam VBLANK = VTOTAL - VACTIVE;   //  30
    localparam BAR_W  = HACTIVE / 8;        // 160

    localparam [23:0] C_BAR0 = 24'hFFFFFF;
    localparam [23:0] C_BAR1 = 24'hFFFF00;
    localparam [23:0] C_BAR2 = 24'h00FFFF;
    localparam [23:0] C_BAR3 = 24'h00FF00;
    localparam [23:0] C_BAR4 = 24'hFF00FF;
    localparam [23:0] C_BAR5 = 24'hFF0000;
    localparam [23:0] C_BAR6 = 24'h0000FF;
    localparam [23:0] C_BAR7 = 24'h000000;

    reg [10:0] S_col_cnt;   // 0 .. HTOTAL-1
    reg [9:0]  S_line_cnt;  // 0 .. VTOTAL-1

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst)
            S_col_cnt <= 11'd0;
        else if (S_col_cnt == HTOTAL - 1)
            S_col_cnt <= 11'd0;
        else
            S_col_cnt <= S_col_cnt + 11'd1;
    end

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst)
            S_line_cnt <= 10'd0;
        else if (S_col_cnt == HTOTAL - 1) begin
            if (S_line_cnt == VTOTAL - 1)
                S_line_cnt <= 10'd0;
            else
                S_line_cnt <= S_line_cnt + 10'd1;
        end
    end

    wire S_active = (S_line_cnt >= VBLANK) && (S_col_cnt >= HBLANK);
    wire [10:0] S_x = S_col_cnt - HBLANK[10:0];

    wire [2:0] S_bar_idx =
        (S_x < BAR_W * 1) ? 3'd0 :
        (S_x < BAR_W * 2) ? 3'd1 :
        (S_x < BAR_W * 3) ? 3'd2 :
        (S_x < BAR_W * 4) ? 3'd3 :
        (S_x < BAR_W * 5) ? 3'd4 :
        (S_x < BAR_W * 6) ? 3'd5 :
        (S_x < BAR_W * 7) ? 3'd6 : 3'd7;

    reg [23:0] S_bar_color;
    always @(*) begin
        case (S_bar_idx)
            3'd0:    S_bar_color = C_BAR0;
            3'd1:    S_bar_color = C_BAR1;
            3'd2:    S_bar_color = C_BAR2;
            3'd3:    S_bar_color = C_BAR3;
            3'd4:    S_bar_color = C_BAR4;
            3'd5:    S_bar_color = C_BAR5;
            3'd6:    S_bar_color = C_BAR6;
            default: S_bar_color = C_BAR7;
        endcase
    end

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            O_video_valid <= 1'b0;
            O_video_user  <= 1'b0;
            O_video_last  <= 1'b0;
            O_video_data  <= 24'd0;
        end else begin
            O_video_valid <= S_active;
            O_video_user  <= (S_line_cnt == VBLANK) && (S_col_cnt == HBLANK);
            O_video_last  <= S_active && (S_col_cnt == HTOTAL - 1);
            O_video_data  <= S_bar_color;
        end
    end

endmodule
