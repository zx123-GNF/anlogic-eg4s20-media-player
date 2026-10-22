//=============================================================================
//  m4_sine_tone.v  --  1 kHz sine test tone generator (M4)
//
//  48 kHz sample rate, 16 bit signed, stereo (L = R), -6.02 dBFS.
//  Runs in the 12.288 MHz WM8960 MCLK domain.
//
//  Method : 32 bit phase accumulator + 1/4 wave sine ROM (m4_sine_rom.v).
//
//      PHASE_INC = round(2^32 * f / fs) = round(2^32 * 1000 / 48000)
//                = 89478485 = 0x05555555
//      f_out     = fs * PHASE_INC / 2^32 = 999.9999963 Hz   (-3.7e-9)
//
//      idx  = phase[31:22]   (1024 points per period = 48 samples per 1 kHz)
//      quad = idx[9:8], a = idx[8] ? ~idx[7:0] : idx[7:0]
//      mag  = rom[a]                      (0 .. 16384 = -6.02 dBFS peak)
//      sign = quad[1]  ->  sample = -mag  (2nd and 3rd quadrant)
//
//  Latency : I_tick -> O_sample = 3 clocks (81 ns * 3 = 244 ns), the I2S
//  transmitter latches the sample 64 BCLK (20.8 us) later, so there is no
//  timing pressure at all.
//
//  Why the tone starts without a click: the phase accumulator is reset to 0 and
//  the sine table starts at sin(0.35 deg) = 50 LSB, so the first samples after
//  I_en are already at the zero crossing - there is no DC step in DACDAT.
//=============================================================================
`timescale 1ns / 10ps

module m4_sine_tone #(
    parameter [31:0] PHASE_INC = 32'd89478485    // 2^32 * 1000 / 48000
)(
    input  wire        I_clk,       // 12.288 MHz audio clock domain
    input  wire        I_rst,       // synchronous, high active
    input  wire        I_tick,      // 1 cycle pulse once per sample (48 kHz)
    input  wire        I_en,        // 0 = mute (outputs 0)
    output reg  [15:0] O_sample     // 16 bit signed sample, L = R
);

    //-------------------------------------------------------------------------
    // phase accumulator
    //   gated by I_en: while the codec is still being initialised the phase
    //   stays at 0, so when the tone is switched on it starts exactly at the
    //   zero crossing of the sine table (rom[0] = 50 LSB) instead of jumping to
    //   an arbitrary phase -> no click.
    //-------------------------------------------------------------------------
    reg [31:0] S_phase;

    always @(posedge I_clk) begin
        if (I_rst)
            S_phase <= 32'd0;
        else if (I_tick && I_en)
            S_phase <= S_phase + PHASE_INC;
    end

    //-------------------------------------------------------------------------
    // quarter wave mirror
    //-------------------------------------------------------------------------
    wire [9:0] S_idx  = S_phase[31:22];
    wire [7:0] S_addr = S_idx[8] ? ~S_idx[7:0] : S_idx[7:0];
    wire       S_neg  = S_idx[9];

    wire [15:0] S_mag;

    m4_sine_rom u_rom (
        .I_clk  (I_clk),
        .I_addr (S_addr),
        .O_data (S_mag)             // valid 1 clock after S_addr
    );

    // sign delayed by the same 1 clock as the ROM
    reg S_neg_r;
    always @(posedge I_clk) begin
        S_neg_r <= S_neg;
    end

    always @(posedge I_clk) begin
        if (I_rst)
            O_sample <= 16'd0;
        else if (!I_en)
            O_sample <= 16'd0;
        else if (S_neg_r)
            O_sample <= (~S_mag) + 16'd1;   // two's complement negation
        else
            O_sample <= S_mag;
    end

endmodule
