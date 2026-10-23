//=============================================================================
//  m5_dbg_vid.v  --  ASCII status line for the M5 video bring-up
//
//  The M5 player has no other observability than 4 LEDs and an 8 digit display,
//  which is not enough to debug a brand new FAT32 streamer.  This module prints
//  one line on the CH340E UART (115200 8N1) every 0.5 s with everything the
//  stream FSM computed:
//
//      V <sst> <vst> <err> <mnt> <frm> <spc> <nfat> <rsvd>
//        <data_lba> <fat_lba> <first_clus> <cur_clus> <lba_used> <file_size>
//
//  all fields in hex without prefix (stream state, vdec state, error, mounted,
//  frames).  The state numbers are the T_* / V_* encodings of rtl/m5_stream.v
//  and rtl/m5_vdec.v, so a hang can be located exactly, and the FAT values can
//  be compared against what a PC sees on the same card.
//=============================================================================
`timescale 1ns / 10ps

module m5_dbg_vid #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115200
) (
    input  wire        I_clk,
    input  wire        I_rst,

    input  wire [5:0]  I_sst,
    input  wire [5:0]  I_vst,
    input  wire [2:0]  I_err,
    input  wire        I_mnt,
    input  wire [15:0] I_frm,

    input  wire [7:0]  I_spc,
    input  wire [31:0] I_mclus,
    input  wire [31:0] I_flba,
    input  wire [31:0] I_fat0,
    input  wire [7:0]  I_b0,
    input  wire [31:0] I_chk,
    input  wire [31:0] I_data_lba,
    input  wire [31:0] I_fat_lba,
    input  wire [31:0] I_first_clus,
    input  wire [31:0] I_clus,
    input  wire [31:0] I_lba,
    input  wire [31:0] I_size,
    input  wire [31:0] I_byt,
    input  wire [5:0]  I_fail,
    input  wire [8:0]  I_secin,

    output reg         O_uart_tx
);

    localparam integer DIV   = CLK_HZ / BAUD;       // 434
    localparam [24:0]  LIMIT = 25'd25_000_000;      // 0.5 s at 50 MHz

    //-------------------------------------------------------------------------
    // transmitter registers (declared before the sequencer that uses them)
    //-------------------------------------------------------------------------
    reg        S_busy;
    reg [15:0] S_bcnt;
    reg [3:0]  S_bidx;
    reg [7:0]  S_lat;

    //-------------------------------------------------------------------------
    // report timer
    //-------------------------------------------------------------------------
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
    // field table : 0 = 'V' prefix, 1..14 = (value, digit count)
    //-------------------------------------------------------------------------
    reg [4:0]  S_fi;
    reg [3:0]  S_di;
    reg [3:0]  S_ndig;
    reg [31:0] S_val;

    always @(*) begin
        case (S_fi)
        4'd1:  begin S_val = {26'd0, I_sst};        S_ndig = 4'd2; end
        4'd2:  begin S_val = {26'd0, I_vst};        S_ndig = 4'd2; end
        4'd3:  begin S_val = {29'd0, I_err};        S_ndig = 4'd2; end
        4'd4:  begin S_val = {31'd0, I_mnt};        S_ndig = 4'd1; end
        4'd5:  begin S_val = {16'd0, I_frm};        S_ndig = 4'd4; end
        4'd6:  begin S_val = {24'd0, I_spc};        S_ndig = 4'd2; end
        4'd7:  begin S_val = I_mclus;              S_ndig = 4'd8; end
        4'd8:  begin S_val = I_flba;               S_ndig = 4'd8; end
        4'd9:  begin S_val = I_fat0;               S_ndig = 4'd8; end
        4'd10: begin S_val = I_chk;                S_ndig = 4'd8; end
        4'd11: begin S_val = I_first_clus;          S_ndig = 4'd8; end
        4'd12: begin S_val = I_clus;                S_ndig = 4'd8; end
        4'd13: begin S_val = I_lba;                 S_ndig = 4'd8; end
        4'd14: begin S_val = I_size;                S_ndig = 4'd8; end
        4'd15: begin S_val = I_byt;                 S_ndig = 4'd8; end
        4'd16: begin S_val = {26'd0, I_fail};       S_ndig = 4'd2; end
        4'd17: begin S_val = {23'd0, I_secin};      S_ndig = 4'd3; end
        4'd18: begin S_val = {24'd0, I_b0};         S_ndig = 4'd2; end
        default: begin S_val = {23'd0, I_secin};     S_ndig = 4'd3; end
        endcase
    end

    wire [3:0] W_nidx = S_ndig - 4'd1 - S_di;
    reg  [3:0] W_nib;
    always @(*) begin
        case (W_nidx)
        4'd0: W_nib = S_val[3:0];
        4'd1: W_nib = S_val[7:4];
        4'd2: W_nib = S_val[11:8];
        4'd3: W_nib = S_val[15:12];
        4'd4: W_nib = S_val[19:16];
        4'd5: W_nib = S_val[23:20];
        4'd6: W_nib = S_val[27:24];
        default: W_nib = S_val[31:28];
        endcase
    end

    function [7:0] hexch;
        input [3:0] n;
        begin
            hexch = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h37 + {4'd0, n});
        end
    endfunction

    //-------------------------------------------------------------------------
    // character sequencer
    //-------------------------------------------------------------------------
    localparam [2:0] Q_IDLE = 3'd0, Q_LD = 3'd1, Q_W1 = 3'd2, Q_W2 = 3'd3,
                     Q_NEXT = 3'd4;

    reg [2:0]  S_q;
    reg        S_txen;
    reg [7:0]  S_chr;
    reg        S_sp;            // the next character is a separator space

    wire [7:0] W_char = S_sp ? 8'h20 : hexch(W_nib);

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_q    <= Q_IDLE;
            S_fi   <= 4'd0;
            S_di   <= 3'd0;
            S_txen <= 1'b0;
            S_chr  <= 8'h00;
            S_sp   <= 1'b0;
        end else begin
            S_txen <= 1'b0;
            case (S_q)
            Q_IDLE: begin
                if (S_go) begin
                    S_fi <= 5'd0;
                    S_di <= 4'd0;
                    S_sp <= 1'b0;
                    S_q  <= Q_LD;
                end
            end
            Q_LD: begin
                if (!S_busy) begin
                    S_chr  <= (S_fi == 5'd0) ? 8'h56 : W_char;
                    S_txen <= 1'b1;
                    S_q    <= Q_W1;
                end
            end
            Q_W1: if (S_busy) S_q <= Q_W2;
            Q_W2: if (!S_busy) S_q <= Q_NEXT;
            Q_NEXT: begin
                if (S_fi == 5'd20) begin
                    S_q <= Q_IDLE;                  // LF sent, line finished
                end else if (S_fi == 5'd20) begin
                    S_chr  <= 8'h0A;                // CR was sent, now LF
                    S_txen <= 1'b1;
                    S_fi   <= 5'd20;
                    S_q    <= Q_W1;
                end else if (S_fi == 5'd0) begin
                    S_fi <= 5'd1;
                    S_di <= 4'd0;
                    S_sp <= 1'b0;
                    S_q  <= Q_LD;
                end else if (S_sp) begin
                    S_sp <= 1'b0;
                    if (S_fi == 5'd19) begin
                        //  one CR LF then back to idle
                        S_chr  <= 8'h0D;
                        S_txen <= 1'b1;
                        S_fi   <= 5'd21;
                        S_q    <= Q_W1;
                    end else begin
                        S_fi <= S_fi + 5'd1;
                        S_di <= 4'd0;
                        S_q  <= Q_LD;
                    end
                end else begin
                    if ((S_di + 4'd1) >= S_ndig) begin
                        S_sp <= 1'b1;
                        S_q  <= Q_LD;
                    end else begin
                        S_di <= S_di + 4'd1;
                        S_q  <= Q_LD;
                    end
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
