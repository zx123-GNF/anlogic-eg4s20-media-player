//=============================================================================
//  m4_hc595.v
//  16 bit serial shifter for the two cascaded 74HC595 of the AC208 7 segment
//  display:  {seg[8], sel[8]} is shifted out MSB first, then latched.
//
//  Derived from the vendor board test source HC595_Driver.v (xiao mei ge,
//  AC201_AL_board_test): same frame format ({seg,sel}, MSB first), same active
//  low segment / active high digit select polarity, same "one 16 bit transfer
//  per 1 kHz scan slot" scheme.  Two deliberate changes:
//
//    * the vendor module reloads its shift register from a free running Data
//      input every clock, so a new {seg,sel} that arrives in the middle of a
//      32 step shift produces a mixture of the old and the new word.  Here the
//      word is captured once, on I_start, and is shifted out as a whole;
//    * the shift clock is 2.5 MHz (one step every DIV = 5 clocks of the 25 MHz
//      pixel clock) instead of the vendor 5 MHz (50 MHz / 10), which is
//      comfortable for the 595s and for the ribbon cable, and still finishes a
//      complete transfer in 16 x 2 / 2.5 MHz = 12.8 us, i.e. in 1.3 % of the
//      1 ms digit slot.
//
//  Timing per bit:  DIO setup -> SCLK rising (595 shifts) -> SCLK falling
//  After the 16th bit: RCLK pulse (595 latches the parallel outputs).
//=============================================================================
`timescale 1ns / 10ps

module m4_hc595 #(
    parameter DIV = 5               // clocks per half bit period
) (
    input  wire        I_clk,       // 25 MHz pixel domain
    input  wire        I_rst,       // active high
    input  wire [15:0] I_data,      // {seg[7:0], sel[7:0]}, stable while I_start
    input  wire        I_start,     // 1 cycle pulse

    output reg         O_sclk,      // SHCP, idle low
    output reg         O_rclk,      // STCP, idle low
    output reg         O_dio        // DS   (SER)
);

    localparam H_IDLE  = 3'd0;
    localparam H_PRE   = 3'd1;      // DIO valid, SCLK low
    localparam H_HI    = 3'd2;      // SCLK high (rising edge shifts)
    localparam H_LATCH = 3'd3;      // RCLK high
    localparam H_LEND  = 3'd4;      // RCLK low

    reg [2:0]  S_st;
    reg [15:0] S_sh;
    reg [3:0]  S_bit;
    reg [2:0]  S_div;

    wire S_step = (S_div == (DIV - 1));

    always @(posedge I_clk) begin
        if (I_rst)
            S_div <= 3'd0;
        else if (S_st == H_IDLE)
            S_div <= 3'd0;
        else
            S_div <= S_step ? 3'd0 : (S_div + 3'd1);
    end

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_st   <= H_IDLE;
            S_sh   <= 16'd0;
            S_bit  <= 4'd0;
            O_sclk <= 1'b0;
            O_rclk <= 1'b0;
            O_dio  <= 1'b0;
        end else begin
            case (S_st)
                H_IDLE: begin
                    O_sclk <= 1'b0;
                    O_rclk <= 1'b0;
                    if (I_start) begin
                        S_sh   <= I_data;
                        S_bit  <= 4'd15;
                        S_st   <= H_PRE;
                    end
                end

                H_PRE: if (S_step) begin
                    O_dio  <= S_sh[15];
                    O_sclk <= 1'b0;
                    S_sh   <= {S_sh[14:0], 1'b0};
                    S_st   <= H_HI;
                end

                H_HI: if (S_step) begin
                    O_sclk <= 1'b1;
                    if (S_bit == 4'd0) begin
                        S_st <= H_LATCH;
                    end else begin
                        S_bit <= S_bit - 4'd1;
                        S_st  <= H_PRE;
                    end
                end

                H_LATCH: if (S_step) begin
                    O_sclk <= 1'b0;
                    O_rclk <= 1'b1;
                    S_st   <= H_LEND;
                end

                H_LEND: if (S_step) begin
                    O_rclk <= 1'b0;
                    S_st   <= H_IDLE;
                end

                default: S_st <= H_IDLE;
            endcase
        end
    end

endmodule
