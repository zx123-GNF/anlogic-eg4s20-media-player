//=============================================================================
//  m5_audio_acr.v  --  HDMI Audio Clock Regeneration packet generator
//
//  Reference: the vendor board test (AC201_AL_board_test) ships this function as
//  src/user_source/hdl_source/audio_arc_calculate.v and feeds it into the
//  encrypted HDMI core, so the same scheme is reproduced here:
//
//    - every AUDIO_DIV = ACR_N/128 = 48 audio samples (= 1 ms at 48 kHz) one
//      ACR packet is produced
//    - CTS is the number of PIXEL clocks counted since the previous packet
//      (measured, not assumed -> independent of the pixel clock / timing)
//    - N = 6144 for 48 kHz  (6272 for 44.1 kHz, 4096 for 32 kHz)
//
//  The sink recovers  fs = f_pixel * N / (128 * CTS)  so the audio clock follows
//  the video clock exactly, whatever the PLL actually produces.
//=============================================================================
`timescale 1ns / 10ps

module m5_audio_acr #(
    parameter integer ACR_N = 6144
) (
    input  wire        I_clk,           // pixel clock
    input  wire        I_rst,           // synchronous, high active
    input  wire        I_audio_valid,   // 1 cycle pulse per audio sample

    output reg         O_acr_valid,
    output reg  [19:0] O_acr_cts,
    output reg  [19:0] O_acr_n
);

    localparam integer AUDIO_DIV = ACR_N >> 7;      // 48 samples @ 48 kHz

    reg  [7:0]  S_div;
    reg  [19:0] S_cts;

    wire S_acr = I_audio_valid && (S_div == (AUDIO_DIV - 1));

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_div       <= 8'd0;
            S_cts       <= 20'd0;
            O_acr_valid <= 1'b0;
            O_acr_cts   <= 20'd0;
            O_acr_n     <= 20'd0;
        end else begin
            if (I_audio_valid)
                S_div <= S_acr ? 8'd0 : (S_div + 8'd1);
            S_cts <= S_acr ? 20'd0 : (S_cts + 20'd1);

            O_acr_valid <= S_acr;
            O_acr_cts   <= S_acr ? (S_cts + 20'd1) : 20'd0;
            O_acr_n     <= S_acr ? ACR_N[19:0]     : 20'd0;
        end
    end

endmodule
