//=============================================================================
//  m4_seg7.v
//  8 digit 7 segment scan / decode / content mux for the AC208 display
//  (2 x 74HC595, 16 bit = {seg[8], sel[8]}), 25 MHz pixel domain.
//
//  Derived from the vendor board test sources (xiao mei ge, AC201_AL_board_test)
//      HEX8.v         : 1 kHz scan (CNT_MAX = 24999 at 50 MHz), rotating one hot
//                       digit select, active low segment decode table, DP = seg
//                       bit 7, sel mask -> module renamed, 25 MHz, 8 digits kept
//      HEX_top.v      : pack {seg, sel} and hand it to the 595 shifter
//  Everything else (what to display, the multi bit CDC and the latch on page
//  completion) is new for M3.
//
//  DISPLAY LAYOUT  (digit 0 = right most, i.e. sel[0]; if the module on the
//  board is wired the other way round set DIG_REV = 1, see below):
//
//      d7 d6   d5 d4   d3 d2 d1 d0
//      |--|    |---|   |---------|
//      cnt     blank   image number (IMGnnnn, zero padded, 4 digits)
//
//      * cnt  = number of indexed images (2 digits, 00..16)
//      * the image number is latched at the page complete pulse, so the
//        number on the display always matches the picture on the screen; it
//        is the 4 digit decimal number of "IMGnnnn.BMP", taken straight out
//        of the file list key (one BCD digit per nibble, no binary->BCD);
//      * DP of d0 lights while the loader is busy (a page is being written);
//      * the whole display blinks at ~2 Hz (0.256 s per half period) while the
//        slide show is paused.
//
//  SPECIAL STATES (no picture on screen)
//      count == 0  and err != 0   ->  "E" + err digit        ("E1".."E3")
//      count == 0  and err == 0   ->  "-" "-"                (still mounting)
//      err == 4 (every candidate BMP was rejected -> the M1 test pattern is on
//      screen)                    ->  "E4"
//
//  MULTI BIT CDC
//  The status bus (mounted, err, count, index, key = 29 bit) is produced in
//  100 MHz domain and is quasi static.  It is 2FF synchronised and then passed
//  through a digital filter that only accepts a value which two consecutive
//  1 kHz scan ticks agree on.  Every bit of the source bus changes on the same
//  100 MHz clock edge, so a mixed sample can live for at most one 25 MHz clock
//  (40 ns) and can never survive the 1 ms filter: no torn value can reach the
//  display.
//=============================================================================
`timescale 1ns / 10ps

module m4_seg7 #(
    // 25 MHz / 25000 = 1 kHz digit scan -> 125 Hz refresh per digit
    parameter SCAN_DIV = 25000,
    // bring-up knob: 0 = the vendor HEX8 mapping (sel[0] = the digit that shows
    // the least significant nibble).  If the module on the board happens to be
    // wired the other way round (the number appears mirrored), set this to 1
    // and the digit order is flipped - the display content is unchanged.
    parameter DIG_REV = 0
) (
    input  wire        I_clk,          // 25 MHz pixel domain
    input  wire        I_rst,          // active high

    // status from the 100 MHz loader (quasi static, filtered here)
    input  wire        I_mounted,      // BPB accepted
    input  wire [2:0]  I_err,          // 0 = ok, else the M2 error code
    input  wire [4:0]  I_count,        // number of *.BMP entries
    input  wire        I_busy,         // page writer busy (loading)
    input  wire [4:0]  I_index,        // list index of the image on screen
    input  wire [15:0] I_key,          // its IMGnnnn key (0xFFFF = not IMGnnnn)

    // interaction status from m4_video_src (same clock domain)
    input  wire        I_paused,       // slide show paused -> blink
    input  wire        I_ready_pulse,  // 1 cycle, a page has just completed

    output reg  [7:0]  O_seg,          // segment drive, active low, bit7 = DP
    output reg  [7:0]  O_sel,          // digit select, one hot, active high
    output reg         O_start         // 1 cycle: {O_seg,O_sel} is stable
);

    //-------------------------------------------------------------------------
    // 1 kHz scan tick + digit counter + blink counter
    //-------------------------------------------------------------------------
    reg [14:0] S_div;
    reg [2:0]  S_dig;
    reg [7:0]  S_blink;

    wire S_tick = (S_div == (SCAN_DIV - 1));

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_div   <= 15'd0;
            S_dig   <= 3'd0;
            S_blink <= 8'd0;
        end else begin
            S_div <= S_tick ? 15'd0 : (S_div + 15'd1);
            if (S_tick) begin
                S_dig   <= S_dig + 3'd1;
                S_blink <= S_blink + 8'd1;      // bit 7: 0.256 s on / 0.256 s off
            end
        end
    end

    //-------------------------------------------------------------------------
    // CDC of the multi bit status bus + digital filter
    //-------------------------------------------------------------------------
    wire [29:0] W_raw = {I_mounted, I_err, I_count, I_index, I_key};  // 1+3+5+5+16

    reg [29:0] S_raw_s1, S_raw_s2;      // 2FF synchroniser
    reg [29:0] S_f_d1,  S_f_d2;         // previous two 1 kHz samples
    reg [29:0] S_stat;                  // accepted value

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_raw_s1 <= 30'd0;
            S_raw_s2 <= 30'd0;
            S_f_d1   <= 30'd0;
            S_f_d2   <= 30'd0;
            S_stat   <= 30'd0;
        end else begin
            S_raw_s1 <= W_raw;
            S_raw_s2 <= S_raw_s1;
            if (S_tick) begin
                S_f_d1 <= S_raw_s2;
                S_f_d2 <= S_f_d1;
                if (S_f_d1 == S_f_d2)
                    S_stat <= S_f_d2;       // stable over 2 ms -> accept
            end
        end
    end

    wire [15:0] W_key   = S_stat[15:0];
    wire [4:0]  W_index = S_stat[20:16];
    wire [4:0]  W_count = S_stat[25:21];
    wire [2:0]  W_err   = S_stat[28:26];
    // carried for completeness; the display decision itself only needs err
    wire        W_mnt   = S_stat[29];

    //-------------------------------------------------------------------------
    // 4 digit number of the picture on screen, latched when the page completes
    //   key != 0xFFFF : the four decimal digits of IMGnnnn (one nibble each)
    //   key == 0xFFFF : fall back to the 1 based list index ("0010" for #10)
    //-------------------------------------------------------------------------
    wire [5:0]  W_idx1 = {1'b0, W_index} + 6'd1;              // 1..16
    wire [3:0]  W_i_lo = (W_idx1 >= 6'd10) ? (W_idx1[3:0] - 4'd10) : W_idx1[3:0];
    wire [3:0]  W_i_hi = (W_idx1 >= 6'd10) ? 4'd1 : 4'd0;
    wire [15:0] W_num  = (W_key != 16'hFFFF) ? W_key
                                             : {8'h00, W_i_hi, W_i_lo};

    reg [15:0] S_num;
    reg        S_have_num;      // at least one page has completed since reset

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_num      <= 16'h0000;
            S_have_num <= 1'b0;
        end else if (I_ready_pulse) begin
            S_num      <= W_num;
            S_have_num <= 1'b1;
        end
    end

    //-------------------------------------------------------------------------
    // total count -> 2 BCD digits (0..16, so the tens digit is 0 or 1)
    //-------------------------------------------------------------------------
    wire [3:0] W_c_lo = (W_count >= 5'd10) ? (W_count[3:0] - 4'd10) : W_count[3:0];
    wire [3:0] W_c_hi = (W_count >= 5'd10) ? 4'd1 : 4'd0;

    //-------------------------------------------------------------------------
    // special states
    //-------------------------------------------------------------------------
    // no number to show yet (boot) / empty list / every candidate BMP rejected
    wire        W_tok     = (!S_have_num) || (W_count == 5'd0) || (W_err == 3'd4);
    wire        W_tok_err = (W_err != 3'd0);
    wire [4:0]  W_t0      = W_tok_err ? {2'b00, W_err}          : 5'h0F;  // err digit
    wire [4:0]  W_t1      = W_tok_err ? {1'b0, 4'hE}             : 5'h0F;  // 'E'

    //-------------------------------------------------------------------------
    // digit content: 5 bit code {blank, bcd[3:0]}
    //-------------------------------------------------------------------------
    wire [4:0] W_d0 = W_tok ? W_t0                    : {1'b0, S_num[3:0]};
    wire [4:0] W_d1 = W_tok ? W_t1                    : {1'b0, S_num[7:4]};
    wire [4:0] W_d2 = W_tok ? 5'h10                   : {1'b0, S_num[11:8]};
    wire [4:0] W_d3 = W_tok ? 5'h10                   : {1'b0, S_num[15:12]};
    wire [4:0] W_d4 = 5'h10;
    wire [4:0] W_d5 = 5'h10;
    wire [4:0] W_d6 = W_tok ? 5'h10                   : {1'b0, W_c_lo};
    wire [4:0] W_d7 = W_tok ? 5'h10                   : {1'b0, W_c_hi};

    reg [4:0] S_code;

    always @(*) begin
        case (S_dig)
            3'd0:    S_code = W_d0;
            3'd1:    S_code = W_d1;
            3'd2:    S_code = W_d2;
            3'd3:    S_code = W_d3;
            3'd4:    S_code = W_d4;
            3'd5:    S_code = W_d5;
            3'd6:    S_code = W_d6;
            3'd7:    S_code = W_d7;
            default: S_code = 5'h10;
        endcase
    end

    //-------------------------------------------------------------------------
    // active low 7 segment decode (vendor HEX8 table, bit 6 = g .. bit 0 = a)
    //-------------------------------------------------------------------------
    function [6:0] SEG7;
        input [3:0] v;
        begin
            case (v)
                4'h0:    SEG7 = 7'b1000000;   // 0
                4'h1:    SEG7 = 7'b1111001;   // 1
                4'h2:    SEG7 = 7'b0100100;   // 2
                4'h3:    SEG7 = 7'b0110000;   // 3
                4'h4:    SEG7 = 7'b0011001;   // 4
                4'h5:    SEG7 = 7'b0010010;   // 5
                4'h6:    SEG7 = 7'b0000010;   // 6
                4'h7:    SEG7 = 7'b1111000;   // 7
                4'h8:    SEG7 = 7'b0000000;   // 8
                4'h9:    SEG7 = 7'b0010000;   // 9
                4'hA:    SEG7 = 7'b0001000;   // A
                4'hB:    SEG7 = 7'b0000011;   // b
                4'hC:    SEG7 = 7'b1000110;   // C
                4'hD:    SEG7 = 7'b0100001;   // d
                4'hE:    SEG7 = 7'b0000110;   // E
                4'hF:    SEG7 = 7'b0111111;   // '-' (segment g only)
                default: SEG7 = 7'b1111111;   // blank
            endcase
        end
    endfunction

    // 100 MHz "loading" flag -> 2FF (single bit, no filter needed)
    reg [1:0] S_busy_sync;

    always @(posedge I_clk) begin
        if (I_rst)
            S_busy_sync <= 2'b00;
        else
            S_busy_sync <= {S_busy_sync[0], I_busy};
    end

    wire S_busy     = S_busy_sync[1];
    wire S_blank    = (I_paused & S_blink[7]) || S_code[4];
    wire S_dot_on   = (S_dig == 3'd0) && S_busy;
    wire [7:0] W_seg = S_blank ? 8'hFF : {~S_dot_on, SEG7(S_code[3:0])};
    wire [7:0] W_sel = (DIG_REV == 0) ? (8'b0000_0001 << S_dig)
                                      : (8'b1000_0000 >> S_dig);

    //-------------------------------------------------------------------------
    // register one digit and start the 595 transfer
    //   O_seg / O_sel are stable for the whole transfer, which takes ~6.4 us
    //   (16 bits at 2.5 MHz SCLK) - far less than the 1 ms digit slot
    //-------------------------------------------------------------------------
    always @(posedge I_clk) begin
        if (I_rst) begin
            O_seg   <= 8'hFF;
            O_sel   <= 8'h00;
            O_start <= 1'b0;
        end else begin
            O_start <= 1'b0;
            if (S_tick) begin
                O_seg   <= W_seg;
                O_sel   <= W_sel;
                O_start <= 1'b1;
            end
        end
    end

endmodule
