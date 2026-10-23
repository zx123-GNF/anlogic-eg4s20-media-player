//=============================================================================
//  m5_vdec.v  --  M5V1 video decoder + frame pacer (100 MHz domain)
//
//  Consumes the byte stream produced by m5_stream and writes complete 640x480
//  pages into the SDRAM ring ("continuous WR1"), one page per video frame.
//
//  WHY A CONTINUOUS RING INSTEAD OF m4_page_wr
//  -------------------------------------------
//  m4_page_wr writes a page row by row and waits DRAIN=4096 clocks between
//  rows (a safety margin for the BMP path).  For a 640x480 page that is
//  480*4096 = 1.97 M clocks = 19.7 ms per frame, which a 15 fps budget of
//  66.7 ms cannot afford on top of the ~50 ms the card needs to deliver the
//  frame.  A video page is exactly 307200 words = 2400 bursts of 128 words,
//  so it can be streamed instead: WR1_LOAD is pulsed once, WR1_ADDR = page A
//  base is the wrap point, and the controller auto-increments in 128 word
//  bursts.  Frames then land on page boundaries by construction and the two
//  display read ports keep seeing page A / page B alternately.
//
//  SOURCE FORMAT (see tools/m5_encode.py)
//  --------------------------------------
//  320x240 RGB332, RLE; frame block = u32 len, u16 audio_samples, u16 bpp,
//  then len bytes of RLE payload, then audio_samples*2 bytes mono s16 (big
//  endian).  Every source pixel becomes a 2x2 block (640x480), so the M4
//  display chain (640x480 window inside 1280x720) needs no change.
//
//  RLE token (16 bit big endian)
//      1 = repeat : count = (tok & 0x0FFF) + 1, next 1 byte is the pixel
//      2 = literal: count = (tok & 0x0FFF) + 1, next count bytes are pixels
//      0 = end of frame
//
//  Pacing: one frame per PERIOD = 100 MHz / fps clocks, so the video time base
//  matches the audio chunks the encoder wrote into the file.
//=============================================================================
`timescale 1ns / 10ps

module m5_vdec #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer FPS    = 15
) (
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire        I_sdram_ready,

    // byte stream from m5_stream
    input  wire        I_byte_valid,
    input  wire [7:0]  I_byte,
    output reg         O_byte_ready,
    input  wire        I_eof,

    // SDRAM write ring (WR1)
    output wire        O_wr,
    output wire [31:0] O_wr_data,
    input  wire        I_wr_full,
    output reg         O_wr_load,
    output wire [20:0] O_wr_addr,

    // page ready handshake to m5_video_src720
    output reg         O_ready_tog,
    output reg         O_ready_page,

    // status
    output wire        O_busy,
    output reg  [15:0] O_frame_cnt,
    output reg  [5:0]  O_st,
    output reg  [2:0]  O_err,

    // audio chunk (mono s16) for the I2S side
    output reg         O_aud_we,
    output reg  [15:0] O_aud_data
);

    localparam integer PERIOD = CLK_HZ / FPS;       // 6_666_666 for 15 fps

    //-------------------------------------------------------------------------
    // frame period timer (free running, a frame may start on the wrap)
    //-------------------------------------------------------------------------
    reg [31:0] S_tmr;
    wire S_tmr_wrap = (S_tmr >= PERIOD - 1);

    always @(posedge I_clk) begin
        if (I_rst)           S_tmr <= 32'd0;
        else if (S_tmr_wrap) S_tmr <= 32'd0;
        else                 S_tmr <= S_tmr + 32'd1;
    end

    //-------------------------------------------------------------------------
    // header / frame header latches
    //-------------------------------------------------------------------------
    reg  [255:0] S_hdr;
    reg  [7:0]   S_hcnt;
    reg  [63:0]  S_fhdr;
    reg  [3:0]   S_fcnt;
    reg  [31:0]  S_len;
    reg  [15:0]  S_aud_n;
    reg  [15:0]  S_aud_i;

    //-------------------------------------------------------------------------
    // row buffer : 320 source pixels of the row being decoded
    //-------------------------------------------------------------------------
    reg  [7:0] S_row [0:319];
    reg  [8:0] S_x;                 // source pixel index 0..319
    reg  [9:0] S_tx;                // output pixel index 0..639
    reg        S_pass;              // the source row is written twice
    reg  [7:0] S_pix;               // pixel of a repeat token
    reg  [11:0] S_left;             // pixels still to write for this token
    reg        S_rep;               // 1 = repeat token, 0 = literal
    reg  [15:0] S_tok;
    reg  [7:0] S_aud_hi;
    reg        S_aud_lo;

    wire [11:0] S_cnt = S_tok[11:0];

    // RGB332 -> RGB888 by bit replication (7 -> 255, 1 -> 36, ...)
    wire [7:0] S_src = S_row[S_tx[9:1]];
    wire [7:0] S_r8  = {S_src[7:5], S_src[7:6], S_src[6:5]};
    wire [7:0] S_g8  = {S_src[4:2], S_src[4:3], S_src[3:2]};
    wire [7:0] S_b8  = {S_src[1:0], S_src[1:0], S_src[1:0], S_src[1:0]};
    wire [23:0] S_rgb = {S_r8, S_g8, S_b8};

    assign O_wr       = (S_st == V_EMIT) && !I_wr_full;
    assign O_wr_data  = {8'h00, S_rgb};
    assign O_wr_addr  = 21'd0;
    assign O_busy     = (S_st != V_WAIT);

    //-------------------------------------------------------------------------
    // FSM
    //-------------------------------------------------------------------------
    localparam [5:0]
        V_WAIT   = 6'd0,
        V_HDR_M  = 6'd1,        // resync : wait for 'M'
        V_HDR_5  = 6'd2,
        V_HDR_V  = 6'd3,
        V_HDR_1  = 6'd4,
        V_HDR_R  = 6'd5,        // remaining 31 header bytes
        V_FRAME  = 6'd6,        // wait for the period boundary
        V_FHDR   = 6'd7,        // 8 byte frame block header
        V_TOKEN0 = 6'd8,
        V_TOKEN1 = 6'd9,
        V_PARSE  = 6'd10,
        V_REPPIX = 6'd11,       // pixel byte of a repeat token
        V_WRITE  = 6'd12,       // write pixels into the row buffer
        V_EMIT   = 6'd13,
        V_AUDIO  = 6'd14,
        V_DONE   = 6'd15;

    reg [5:0] S_st;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_st         <= V_WAIT;
            S_hdr        <= 256'd0;
            S_hcnt       <= 8'd0;
            S_fhdr       <= 64'd0;
            S_fcnt       <= 4'd0;
            S_len        <= 32'd0;
            S_aud_n      <= 16'd0;
            S_aud_i      <= 16'd0;
            S_aud_lo     <= 1'b0;
            S_aud_hi     <= 8'd0;
            S_pix        <= 8'd0;
            S_left       <= 12'd0;
            S_rep        <= 1'b0;
            S_tok        <= 16'd0;
            S_x          <= 9'd0;
            S_tx         <= 10'd0;
            S_pass       <= 1'b0;
            O_byte_ready <= 1'b0;
            O_wr_load    <= 1'b0;
            O_ready_tog  <= 1'b0;
            O_ready_page <= 1'b0;
            O_frame_cnt  <= 16'd0;
            O_st         <= V_WAIT;
            O_err        <= 3'd0;
            O_aud_we     <= 1'b0;
            O_aud_data   <= 16'd0;
        end else begin
            O_st         <= S_st;
            O_wr_load    <= 1'b0;
            O_aud_we     <= 1'b0;
            O_byte_ready <= 1'b0;

            case (S_st)
            //------------------------------------------------- start
            V_WAIT: begin
                if (I_sdram_ready) begin
                    O_wr_load <= 1'b1;
                    S_st      <= V_HDR_M;
                end
            end
            //------------------------------------------------- header resync
            V_HDR_M: begin
                O_byte_ready <= 1'b1;
                if (I_byte_valid && I_byte == 8'h4D) S_st <= V_HDR_5;
            end
            V_HDR_5: begin
                O_byte_ready <= 1'b1;
                if (I_byte_valid) S_st <= (I_byte == 8'h35) ? V_HDR_V : V_HDR_M;
            end
            V_HDR_V: begin
                O_byte_ready <= 1'b1;
                if (I_byte_valid) S_st <= (I_byte == 8'h56) ? V_HDR_1 : V_HDR_M;
            end
            V_HDR_1: begin
                O_byte_ready <= 1'b1;
                if (I_byte_valid) begin
                    if (I_byte == 8'h31) begin
                        S_hdr  <= {S_hdr[247:0], I_byte};
                        S_hcnt <= 8'd1;
                        S_st   <= V_HDR_R;
                    end else
                        S_st <= V_HDR_M;
                end
            end
            V_HDR_R: begin
                O_byte_ready <= 1'b1;
                if (I_byte_valid) begin
                    S_hdr  <= {S_hdr[247:0], I_byte};
                    S_hcnt <= S_hcnt + 8'd1;
                    if (S_hcnt == 8'd31) begin
                        // byte i sits at bits [255-8i : 248-8i]  (S_hdr holds
                        // bytes 0..30 here, which is all we need: bpp is at
                        // bytes 10..11 = bits 175:160)
                        if (S_hdr[175:160] != 16'd1) begin
                            O_err <= 3'd1;                  // not RGB332
                            S_st  <= V_HDR_M;
                        end else
                            S_st <= V_FRAME;
                    end
                end
            end
            //------------------------------------------------- frame boundary
            V_FRAME: begin
                if (S_tmr_wrap) begin
                    S_fcnt  <= 4'd0;
                    S_fhdr  <= 64'd0;
                    S_st    <= V_FHDR;
                end
            end
            V_FHDR: begin
                O_byte_ready <= 1'b1;
                if (I_byte_valid) begin
                    S_fhdr <= {S_fhdr[55:0], I_byte};
                    S_fcnt <= S_fcnt + 4'd1;
                    if (S_fcnt == 4'd7) begin
                        // S_fhdr holds bytes 0..6 (b0 in bits 55:48), I_byte is b7
                        S_len   <= S_fhdr[55:24];
                        S_aud_n <= S_fhdr[23:8];
                        S_aud_i <= 16'd0;
                        S_x     <= 9'd0;
                        S_st    <= V_TOKEN0;
                    end
                end
            end
            //------------------------------------------------- RLE tokens
            V_TOKEN0: begin
                O_byte_ready <= 1'b1;
                if (I_byte_valid) begin
                    S_tok[15:8] <= I_byte;
                    S_st        <= V_TOKEN1;
                end
            end
            V_TOKEN1: begin
                O_byte_ready <= 1'b1;
                if (I_byte_valid) begin
                    S_tok[7:0] <= I_byte;
                    S_st       <= V_PARSE;
                end
            end
            V_PARSE: begin
                if (S_tok[15:12] == 4'd0) begin
                    // end of frame
                    S_aud_i <= 16'd0;
                    S_aud_lo <= 1'b0;
                    S_st    <= (S_aud_n != 16'd0) ? V_AUDIO : V_DONE;
                end else begin
                    S_left <= S_cnt + 12'd1;
                    S_rep  <= (S_tok[15:12] == 4'd1);
                    S_st   <= (S_tok[15:12] == 4'd1) ? V_REPPIX : V_WRITE;
                end
            end
            V_REPPIX: begin
                O_byte_ready <= 1'b1;
                if (I_byte_valid) begin
                    S_pix <= I_byte;
                    S_st  <= V_WRITE;
                end
            end
            V_WRITE: begin
                if (S_rep) begin
                    // no bytes to consume, just replicate
                    S_row[S_x] <= S_pix;
                    S_x        <= S_x + 9'd1;
                    S_left     <= S_left - 12'd1;
                    if (S_x == 9'd319) begin
                        S_x    <= 9'd0;
                        S_tx   <= 10'd0;
                        S_pass <= 1'b0;
                        S_st   <= V_EMIT;
                    end else if (S_left == 12'd1) begin
                        S_st <= V_TOKEN0;
                    end
                end else begin
                    O_byte_ready <= 1'b1;
                    if (I_byte_valid) begin
                        S_row[S_x] <= I_byte;
                        S_x        <= S_x + 9'd1;
                        S_left     <= S_left - 12'd1;
                        if (S_x == 9'd319) begin
                            S_x    <= 9'd0;
                            S_tx   <= 10'd0;
                            S_pass <= 1'b0;
                            S_st   <= V_EMIT;
                        end else if (S_left == 12'd1) begin
                            S_st <= V_TOKEN0;
                        end
                    end
                end
            end
            //------------------------------------------------- emit two rows
            V_EMIT: begin
                if (!I_wr_full) begin
                    if (S_tx == 10'd639) begin
                        S_tx <= 10'd0;
                        if (S_pass == 1'b0)
                            S_pass <= 1'b1;
                        else begin
                            S_pass <= 1'b0;
                            S_st   <= (S_left != 12'd0) ? V_WRITE : V_TOKEN0;
                        end
                    end else
                        S_tx <= S_tx + 10'd1;
                end
            end
            //------------------------------------------------- audio chunk
            V_AUDIO: begin
                O_byte_ready <= 1'b1;
                if (I_byte_valid) begin
                    if (!S_aud_lo) begin
                        S_aud_hi <= I_byte;
                        S_aud_lo <= 1'b1;
                    end else begin
                        O_aud_we   <= 1'b1;
                        O_aud_data <= {S_aud_hi, I_byte};
                        S_aud_lo   <= 1'b0;
                    end
                    S_aud_i <= S_aud_i + 16'd1;
                    if ((S_aud_i + 16'd1) >= {S_aud_n, 1'b0}) S_st <= V_DONE;
                end
            end
            //------------------------------------------------- frame done
            V_DONE: begin
                O_ready_page <= O_frame_cnt[0];
                O_ready_tog  <= ~O_ready_tog;
                O_frame_cnt  <= O_frame_cnt + 16'd1;
                S_st         <= V_FRAME;
            end
            default: S_st <= V_WAIT;
            endcase
        end
    end

endmodule
