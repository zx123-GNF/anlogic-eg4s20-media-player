//=============================================================================
//  m5_dbg_vid.v  --  ASCII status line for the M5 video bring-up
//
//  The M5 player has no other observability: the four LEDs only tell "mounted",
//  "busy", "error", "page", which is not enough to debug a brand new FAT32
//  streamer.  This module prints one fixed width ASCII line on the CH340E UART
//  (115200 8N1) every 0.5 s:
//
//      V <vdec state> <stream state> <err> <mounted> <frames> <bytes>\r\n
//        ^ 2 hex       ^ 2 hex       2 hex  1 hex     4 hex    8 hex
//
//  e.g.  V 0d 28 00 1 0000 00000000  -> vdec state 13 (V_EMIT),
//        stream state 0x28 (T_FAT_CL_W), no error, mounted, 0 frames so far.
//
//  The states are the same numbers as in rtl/m5_stream.v (T_*) and
//  rtl/m5_vdec.v (V_*), so a stream that hangs shows exactly where.
//=============================================================================
`timescale 1ns / 10ps

module m5_dbg_vid #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115200
) (
    input  wire        I_clk,
    input  wire        I_rst,

    input  wire [5:0]  I_vst,
    input  wire [5:0]  I_sst,
    input  wire [2:0]  I_err,
    input  wire        I_mnt,
    input  wire [15:0] I_frm,
    input  wire [31:0] I_byt,

    output reg         O_uart_tx
);

    localparam integer DIV   = CLK_HZ / BAUD;       // 434
    localparam integer CHARS = 28;
    localparam [24:0]  LIMIT = 25'd25_000_000;      // 0.5 s at 50 MHz

    reg [24:0] S_rep;
    reg        S_go;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_rep <= 25'd0;
            S_go  <= 1'b0;
        end else begin
            S_go <= 1'b0;
            if (S_rep >= LIMIT) begin
                S_rep <= 25'd0;
                S_go  <= 1'b1;
            end else
                S_rep <= S_rep + 25'd1;
        end
    end

    //-------------------------------------------------------------------------
    // character sequencer
    //-------------------------------------------------------------------------
    function [7:0] hexch;
        input [3:0] n;
        begin
            hexch = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h37 + {4'd0, n});
        end
    endfunction

    // 8N1 transmitter registers (declared before the sequencer that uses them)
    reg        S_busy;
    reg [15:0] S_bcnt;
    reg [3:0]  S_bidx;
    reg [7:0]  S_lat;

    reg [4:0]  S_c;
    reg [2:0]  S_q;
    reg        S_txen;
    reg [7:0]  S_chr;
    reg [7:0]  S_nib;

    reg [7:0] W_chr;
    always @(*) begin
        case (S_c)
        5'd0:  W_chr = 8'h56;                       // 'V'
        5'd1:  W_chr = 8'h20;
        5'd2:  W_chr = hexch({2'b00, I_vst[5:4]});
        5'd3:  W_chr = hexch(I_vst[3:0]);
        5'd4:  W_chr = 8'h20;
        5'd5:  W_chr = hexch({2'b00, I_sst[5:4]});
        5'd6:  W_chr = hexch(I_sst[3:0]);
        5'd7:  W_chr = 8'h20;
        5'd8:  W_chr = 8'h30;
        5'd9:  W_chr = hexch({1'b0, I_err});
        5'd10: W_chr = 8'h20;
        5'd11: W_chr = I_mnt ? 8'h31 : 8'h30;
        5'd12: W_chr = 8'h20;
        5'd13: W_chr = hexch(I_frm[15:12]);
        5'd14: W_chr = hexch(I_frm[11:8]);
        5'd15: W_chr = hexch(I_frm[7:4]);
        5'd16: W_chr = hexch(I_frm[3:0]);
        5'd17: W_chr = 8'h20;
        5'd18: W_chr = hexch(I_byt[31:28]);
        5'd19: W_chr = hexch(I_byt[27:24]);
        5'd20: W_chr = hexch(I_byt[23:20]);
        5'd21: W_chr = hexch(I_byt[19:16]);
        5'd22: W_chr = hexch(I_byt[15:12]);
        5'd23: W_chr = hexch(I_byt[11:8]);
        5'd24: W_chr = hexch(I_byt[7:4]);
        5'd25: W_chr = hexch(I_byt[3:0]);
        5'd26: W_chr = 8'h0D;
        default: W_chr = 8'h0A;
        endcase
    end

    localparam [2:0] Q_IDLE = 3'd0, Q_LD = 3'd1, Q_W1 = 3'd2, Q_W2 = 3'd3, Q_NEXT = 3'd4;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_q    <= Q_IDLE;
            S_c    <= 5'd0;
            S_txen <= 1'b0;
            S_chr  <= 8'd0;
        end else begin
            S_txen <= 1'b0;
            case (S_q)
                Q_IDLE: begin
                    if (S_go) begin
                        S_c <= 5'd0;
                        S_q <= Q_LD;
                    end
                end
                Q_LD: begin
                    if (!S_busy) begin
                        S_chr  <= W_chr;
                        S_txen <= 1'b1;
                        S_q    <= Q_W1;
                    end
                end
                Q_W1: begin
                    if (S_busy) S_q <= Q_W2;
                end
                Q_W2: begin
                    if (!S_busy) S_q <= Q_NEXT;
                end
                Q_NEXT: begin
                    if (S_c == CHARS - 1) S_q <= Q_IDLE;
                    else begin
                        S_c <= S_c + 5'd1;
                        S_q <= Q_LD;
                    end
                end
                default: S_q <= Q_IDLE;
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // 8N1 transmitter
    //-------------------------------------------------------------------------
    always @(posedge I_clk) begin
        if (I_rst) begin
            O_uart_tx <= 1'b1;
            S_busy    <= 1'b0;
            S_bcnt    <= 16'd0;
            S_bidx    <= 4'd0;
            S_lat     <= 8'h00;
        end else if (!S_busy) begin
            O_uart_tx <= 1'b1;
            if (S_txen) begin
                S_lat     <= S_chr;
                S_busy    <= 1'b1;
                S_bcnt    <= 16'd0;
                S_bidx    <= 4'd0;
                O_uart_tx <= 1'b0;
            end
        end else if (S_bcnt == DIV - 1) begin
            S_bcnt <= 16'd0;
            if (S_bidx == 4'd9) begin
                S_busy    <= 1'b0;
                O_uart_tx <= 1'b1;
            end else begin
                S_bidx    <= S_bidx + 4'd1;
                O_uart_tx <= (S_bidx == 4'd8) ? 1'b1 : S_lat[S_bidx];
            end
        end else
            S_bcnt <= S_bcnt + 16'd1;
    end

endmodule
