//=============================================================================
//  m5_i2s_tx.v  --  I2S transmitter, FPGA is master (M4)
//
//  Standard Philips I2S, 48 kHz, 16 bit data in a 64 BCLK frame (2 x 32 bit
//  slots), DACDAT updated on the BCLK falling edge.
//
//  Clock generation (all derived from the 12.288136 MHz MCLK, no extra PLL)
//      MCLK  12.288136 MHz
//      BCLK  = MCLK / 4    = 3.072034 MHz      (64 x fs, 50 % duty)
//      LRCK  = BCLK / 64   = 48.00053 kHz      (low = left channel)
//
//  Frame format (64 BCLK per frame, slot 0..63)
//      slot  0        : LRCK goes low  (left channel), DACDAT = 0
//      slot  1 .. 16  : left  data bit 15 .. bit 0   (MSB first)
//      slot 17 .. 31  : 0  (16 bit word in a 32 bit slot)
//      slot 32        : LRCK goes high (right channel), DACDAT = 0
//      slot 33 .. 48  : right data bit 15 .. bit 0
//      slot 49 .. 63  : 0
//
//  This is exactly the datasheet definition of I2S ("the MSB is available on the
//  second rising edge of BCLK following a LRCK transition", WM8960 datasheet
//  page 49): LRCK changes on a BCLK falling edge, the MSB appears one BCLK
//  later, so the receiver samples it on the 2nd rising edge.  Data changes on
//  the falling edge, the codec samples on the rising edge -> half a BCLK
//  (162 ns) of setup and hold.
//
//  Because the codec is programmed for 16 bit words (R7 WL = 00) it consumes
//  only the first 16 bits of each slot and ignores the remaining 16 BCLK, which
//  is the normal way to run 16 bit audio in a 32 bit slot.
//
//  Slot 32 is also where the next sample is requested from m5_sine_tone through
//  O_tick; slot 0 latches it for both channels.
//=============================================================================
`timescale 1ns / 10ps

module m5_i2s_tx (
    input  wire        I_clk,       // 12.288136 MHz MCLK
    input  wire        I_rst,       // synchronous, high active
    input  wire        I_en,        // 0 = DACDAT forced low (silence)
    input  wire [15:0] I_sample,    // current 16 bit sample (both channels)
    output reg         O_tick,      // 1 cycle pulse at the frame start

    output wire        O_mclk,      // to codec MCLK   (B8)
    output reg         O_bclk,      // to codec SCLK   (C8)
    output reg         O_lrck,      // to codec LRCK   (A7)
    output reg         O_dacdat     // to codec DSDIN  (A8)
);

    assign O_mclk = I_clk;

    //-------------------------------------------------------------------------
    // bit clock : BCLK = MCLK / 4, falling edge when S_mcnt == 0
    //-------------------------------------------------------------------------
    reg [1:0] S_mcnt;       // 0..3, free running
    reg [5:0] S_slot;       // 0..63 inside one frame
    reg [15:0] S_sl;        // left  sample latched at slot 0
    reg [15:0] S_sr;        // right sample latched at slot 0

    wire [5:0] S_nslot = S_slot + 6'd1;
    wire [4:0] S_off   = S_nslot[4:0];                  // 0..31 in the half frame
    wire [15:0] S_src  = S_nslot[5] ? S_sr : S_sl;
    wire [3:0] S_bidx  = (5'd16 - S_off);               // legal 4 bit index
    wire       S_bitv  = ((S_off >= 5'd1) && (S_off <= 5'd16)) ? S_src[S_bidx] : 1'b0;

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_mcnt   <= 2'd0;
            S_slot   <= 6'd0;
            S_sl     <= 16'd0;
            S_sr     <= 16'd0;
            O_bclk   <= 1'b0;
            O_lrck   <= 1'b0;
            O_dacdat <= 1'b0;
            O_tick   <= 1'b0;
        end
        else begin
            S_mcnt <= S_mcnt + 2'd1;
            O_tick <= 1'b0;

            if (S_mcnt == 2'd0) begin
                //----------------------------------------- BCLK falling edge
                O_bclk   <= 1'b0;
                S_slot   <= S_nslot;
                O_lrck   <= S_nslot[5];
                O_dacdat <= I_en ? S_bitv : 1'b0;

                if (S_nslot == 6'd0) begin
                    // new frame : take the next sample for both channels and
                    // ask the tone generator for the following one
                    S_sl   <= I_sample;
                    S_sr   <= I_sample;
                    O_tick <= 1'b1;
                end
            end
            else if (S_mcnt == 2'd2) begin
                //----------------------------------------- BCLK rising edge
                O_bclk <= 1'b1;
            end
        end
    end

endmodule
