//=============================================================================
//  m4_dbg_uart.v
//  One-shot debug dumper: snapshot the first MAXREC byte_seq reads (offset,
//  count, FSM state, payload) into plain registers and print them as text on
//  the CH340E UART (115200 8N1).
//
//  Why: the SD/FAT path has no other observable output on this board.  Three
//  LEDs can only show an error code, not what the card actually returned.
//
//  Line format, one line per record:
//      <'A'+record> <off hi><off lo> <cnt> <state> <34 bytes as hex> CR LF
//  e.g. "A0BE0818ffff..." = record 0, offset 0x0BE, 8 bytes, FSM state 0x18.
//
//  Printing starts MAXREC records after reset, or 0.5 s after reset if fewer
//  were captured (the FAT FSM stops early on an error).  One shot only.
//
//  IMPLEMENTATION NOTES (both learned the hard way on this design):
//   * storage is 4 flat 293 bit registers, NOT a 304 byte array written by a
//     for loop: TD turned that into a huge mux tree and the 100 MHz domain
//     went to SWNS -5.2 ns / STNS -374 ns.
//   * the character is built in three pipelined register stages (index ->
//     payload byte -> hex digits).  One combined mux needs 11.5 ns and still
//     violated setup by 1.4 ns; a UART bit lasts 868 clocks, so three cycles
//     per character cost nothing.
//=============================================================================
`timescale 1ns / 10ps

module m4_dbg_uart #(
    parameter CLK_HZ = 100_000_000,
    parameter BAUD   = 115200,
    parameter MAXREC = 8
) (
    input  wire         I_clk,
    input  wire         I_rst,

    // byte_seq observation port (100 MHz domain)
    input  wire         I_bs_done,
    input  wire [8:0]   I_off,
    input  wire [5:0]   I_cnt,
    input  wire [5:0]   I_st,
    input  wire [271:0] I_val,

    // live FSM status, printed as the extra 'I' record every pass
    input  wire [5:0]   I_live_st,
    input  wire [2:0]   I_live_err,
    input  wire [7:0]   I_live_ck,

    output reg          O_uart_tx
);

    localparam integer DIV = CLK_HZ / BAUD;     // 868 for 100 MHz / 115200
    localparam integer NPL = 34;                // payload bytes
    localparam integer REC = 4 + NPL;           // off lo/hi + cnt + st + payload
    localparam integer CHR = 1 + 2*REC + 2;     // prefix + hex + CR LF

    //-------------------------------------------------------------------------
    // snapshot registers:  {payload 34 bytes, st, cnt, off[8:0]}
    //-------------------------------------------------------------------------
    reg [292:0] S_r0, S_r1, S_r2, S_r3, S_r4, S_r5, S_r6, S_r7;
    reg [3:0]   S_nrec;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_nrec <= 4'd0;
            S_r0   <= 293'd0;
            S_r1   <= 293'd0;
            S_r2   <= 293'd0;
            S_r3   <= 293'd0;
            S_r4   <= 293'd0;
            S_r5   <= 293'd0;
            S_r6   <= 293'd0;
            S_r7   <= 293'd0;
        end else if (I_bs_done) begin
            case (S_nrec)
                4'd0: S_r0 <= {I_val, I_st, I_cnt, I_off};
                4'd1: S_r1 <= {I_val, I_st, I_cnt, I_off};
                4'd2: S_r2 <= {I_val, I_st, I_cnt, I_off};
                4'd3: S_r3 <= {I_val, I_st, I_cnt, I_off};
                4'd4: S_r4 <= {I_val, I_st, I_cnt, I_off};
                4'd5: S_r5 <= {I_val, I_st, I_cnt, I_off};
                4'd6: S_r6 <= {I_val, I_st, I_cnt, I_off};
                4'd7: S_r7 <= {I_val, I_st, I_cnt, I_off};
                default: ;
            endcase
            if (S_nrec != 4'd8) S_nrec <= S_nrec + 4'd1;
        end
    end

    //-------------------------------------------------------------------------
    // repeat timer: print a pass every 0.6 s (first one 0.6 s after reset).
    // Repeating instead of one-shot means the PC never has to be listening at
    // the exact moment of the reset, and a pass with zero captured records
    // still sends "A00..." as a heartbeat, which separates "UART path broken"
    // from "nothing captured".
    //-------------------------------------------------------------------------
    reg [26:0] S_rep;
    reg        S_go_pass;
    reg        S_pass_done;
    reg [3:0]  S_nprint;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_rep     <= 27'd0;
            S_go_pass <= 1'b0;
            S_nprint  <= 4'd1;
        end else begin
            S_go_pass <= 1'b0;
            if (S_pass_done) begin
                S_rep <= 27'd0;
            end else if (S_rep == 27'd60_000_000) begin
                S_rep     <= 27'd0;
                S_go_pass <= 1'b1;
                S_nprint  <= ((S_nrec == 4'd0) ? 4'd1 : S_nrec) + 4'd1;
            end else
                S_rep <= S_rep + 27'd1;
        end
    end

    //-------------------------------------------------------------------------
    // character pipeline
    //   stage A : index maths      (S_c -> S_b_r / S_bp_r / S_hi_r / S_cur_r)
    //   stage B : payload byte     (record mux + byte mux -> S_pb_r)
    //   stage C : hex digits       (S_pb_r -> S_byte)
    //-------------------------------------------------------------------------
    localparam Q_IDLE = 3'd0, Q_A = 3'd1, Q_B = 3'd2, Q_C = 3'd3,
               Q_WAIT = 3'd4, Q_NEXT = 3'd5;

    reg [2:0]  S_q;
    reg [3:0]  S_r;         // record index, 8 = live status
    reg [6:0]  S_c;         // char index inside the record
    reg [5:0]  S_b_r;       // payload byte index, stage A
    reg [5:0]  S_bp_r;
    reg        S_hi_r;
    reg [292:0] S_cur_r;
    reg [7:0]  S_pb_r;      // payload byte, stage B
    reg        S_go;
    reg [7:0]  S_byte;
    reg        S_busy;
    reg [15:0] S_bcnt;
    reg [3:0]  S_bidx;
    reg [7:0]  S_lat;

    // stage A: index arithmetic (from S_c and S_r only)
    wire [5:0] S_b    = (S_c == 7'd0) ? 6'd0 : ((S_c - 7'd1) >> 1);
    wire [5:0] S_bp   = (S_b < 6'd4)  ? 6'd0 : (S_b - 6'd4);
    wire        S_is_live = (S_r >= S_nrec);
    wire [292:0] S_rec = S_is_live ? S_live :
                         (S_r == 4'd0) ? S_r0 :
                         (S_r == 4'd1) ? S_r1 :
                         (S_r == 4'd2) ? S_r2 :
                         (S_r == 4'd3) ? S_r3 :
                         (S_r == 4'd4) ? S_r4 :
                         (S_r == 4'd5) ? S_r5 :
                         (S_r == 4'd6) ? S_r6 :
                         (S_r == 4'd7) ? S_r7 : S_live;

    // stage B: one byte out of the record (38 way mux, registered)
    wire [292:0] S_live = {{263'd0, I_live_ck}, I_live_st, 3'd0, I_live_err, 9'd0};

    wire [7:0] S_pb  = (S_b_r == 6'd0) ? S_cur_r[7:0]  :          // off low
                       (S_b_r == 6'd1) ? {7'd0, S_cur_r[8]} :     // off high
                       (S_b_r == 6'd2) ? {2'd0, S_cur_r[14:9]} :  // cnt
                       (S_b_r == 6'd3) ? {2'd0, S_cur_r[20:15]} : // state
                                         S_cur_r[8*S_bp_r + 21 +: 8];

    // stage C: hex digits (from registered values only)
    wire [3:0] S_nib = S_hi_r ? S_pb_r[7:4] : S_pb_r[3:0];
    wire [7:0] S_chr = (S_c == 7'd0)    ? (S_is_live ? 8'h5A : (8'h41 + {4'd0, S_r})) :
                       (S_c == CHR - 2) ? 8'h0D :
                       (S_c == CHR - 1) ? 8'h0A :
                       (S_nib < 4'd10)  ? (8'h30 + {4'h0, S_nib}) :
                                          (8'h37 + {4'h0, S_nib});

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_q     <= Q_IDLE;
            S_r     <= 4'd0;
            S_c     <= 7'd0;
            S_b_r   <= 6'd0;
            S_bp_r  <= 6'd0;
            S_hi_r  <= 1'b0;
            S_cur_r <= 293'd0;
            S_pb_r  <= 8'd0;
            S_go    <= 1'b0;
            S_byte  <= 8'd0;
        end else begin
            S_go        <= 1'b0;
            S_pass_done <= 1'b0;

            case (S_q)
                Q_IDLE: begin
                    if (S_go_pass) begin
                        S_r <= 4'd0;
                        S_c <= 7'd0;
                        S_q <= Q_A;
                    end
                end

                Q_A: begin                       // index maths
                    S_b_r   <= S_b;
                    S_bp_r  <= S_bp;
                    S_hi_r  <= S_c[0];
                    S_cur_r <= S_rec;
                    S_q     <= Q_B;
                end

                Q_B: begin                       // payload byte mux
                    S_pb_r <= S_pb;
                    S_q    <= Q_C;
                end

                Q_C: begin                       // hex digits + start TX
                    if (!S_busy) begin
                        S_byte <= S_chr;
                        S_go   <= 1'b1;
                        S_q    <= Q_WAIT;
                    end
                end

                Q_WAIT: begin
                    if (S_busy) S_q <= Q_NEXT;
                end

                Q_NEXT: begin
                    if (!S_busy) begin
                        if (S_c == CHR - 1) begin
                            S_c <= 7'd0;
                            if (S_r == (S_nprint - 4'd1)) begin
                                S_pass_done <= 1'b1;
                                S_q   <= Q_IDLE;
                            end else begin
                                S_r <= S_r + 4'd1;
                                S_q <= Q_A;
                            end
                        end else begin
                            S_c <= S_c + 7'd1;
                            S_q <= Q_A;
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
            if (S_go) begin
                S_lat     <= S_byte;
                S_busy    <= 1'b1;
                S_bcnt    <= 16'd0;
                S_bidx    <= 4'd0;
                O_uart_tx <= 1'b0;                   // start bit
            end
        end else if (S_bcnt == DIV - 1) begin
            S_bcnt <= 16'd0;
            if (S_bidx == 4'd9) begin
                S_busy    <= 1'b0;
                O_uart_tx <= 1'b1;
            end else begin
                S_bidx <= S_bidx + 4'd1;
                O_uart_tx <= (S_bidx == 4'd8) ? 1'b1 : S_lat[S_bidx];
            end
        end else
            S_bcnt <= S_bcnt + 16'd1;
    end

endmodule
