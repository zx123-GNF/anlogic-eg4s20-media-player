//=============================================================================
//  video_gen.v
//  M0 milestone AXIS video source: 640x480, 8 vertical colour bars, RGB888.
//
//  The counters run free on the pixel clock and are reset together with the
//  HDMI core, so the pixel stream stays phase locked to the core's internal
//  timing generator (both are started by the same I_rst release).
//
//  AXIS mapping expected by hdmi_1_4b_transmitter_core:
//      O_video_user  : start of frame (first active pixel of the frame)
//      O_video_valid : pixel data valid (active video only)
//      O_video_last  : last active pixel of the line
//      O_video_data  : {R[7:0], G[7:0], B[7:0]}
//=============================================================================
`timescale 1ns / 10ps

module video_gen #(
    parameter HTOTAL  = 800,
    parameter HSA     = 96,
    parameter HBP     = 48,
    parameter HFP     = 16,
    parameter HACTIVE = 640,

    parameter VTOTAL  = 525,
    parameter VSA     = 2,
    parameter VBP     = 33,
    parameter VFP     = 10,
    parameter VACTIVE = 480
) (
    input  wire        I_clk,           // pixel clock (25 MHz)
    input  wire        I_rst,           // active high

    output reg         O_video_user,
    output reg         O_video_valid,
    output reg         O_video_last,
    output reg  [23:0] O_video_data,
    input  wire        I_video_ready    // accepted but not used (see report)
);

    localparam HBLANK = HTOTAL - HACTIVE;   // 160
    localparam VBLANK = VTOTAL - VACTIVE;   //  45
    localparam BAR_W  = HACTIVE / 8;        //  80

    // 8 vertical bars: white, yellow, cyan, green, magenta, red, blue, black
    localparam [23:0] C_BAR0 = 24'hFFFFFF;
    localparam [23:0] C_BAR1 = 24'hFFFF00;
    localparam [23:0] C_BAR2 = 24'h00FFFF;
    localparam [23:0] C_BAR3 = 24'h00FF00;
    localparam [23:0] C_BAR4 = 24'hFF00FF;
    localparam [23:0] C_BAR5 = 24'hFF0000;
    localparam [23:0] C_BAR6 = 24'h0000FF;
    localparam [23:0] C_BAR7 = 24'h000000;

    reg [9:0] S_col_cnt;    // 0 .. HTOTAL-1
    reg [9:0] S_line_cnt;   // 0 .. VTOTAL-1

    //-------------------------------------------------------------------------
    // free running horizontal / vertical counters
    //-------------------------------------------------------------------------
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst)
            S_col_cnt <= 10'd0;
        else if (S_col_cnt == HTOTAL - 1)
            S_col_cnt <= 10'd0;
        else
            S_col_cnt <= S_col_cnt + 10'd1;
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

    wire S_active  = (S_line_cnt >= VBLANK) && (S_col_cnt >= HBLANK);
    wire [9:0] S_x  = S_col_cnt - HBLANK[9:0];   // 0 .. HACTIVE-1 in active area

    //-------------------------------------------------------------------------
    // 8 colour bars, 80 pixels each
    //-------------------------------------------------------------------------
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

    //-------------------------------------------------------------------------
    // AXIS outputs: valid / data / user / last are registered together so the
    // beat always carries the pixel that was active on the counter cycle.
    //-------------------------------------------------------------------------
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            O_video_valid <= 1'b0;
            O_video_user  <= 1'b0;
            O_video_last  <= 1'b0;
            O_video_data  <= 24'd0;
        end else begin
            O_video_valid <= S_active;
            O_video_user  <= (S_line_cnt == VBLANK) && (S_col_cnt == HBLANK);
            // last active pixel of the line : column HBLANK+HACTIVE-1 = HTOTAL-1
            O_video_last  <= S_active && (S_col_cnt == HTOTAL - 1);
            O_video_data  <= S_bar_color;
        end
    end

endmodule
