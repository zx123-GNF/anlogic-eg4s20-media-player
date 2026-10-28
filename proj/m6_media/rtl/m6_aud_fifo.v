//=============================================================================
//  m6_aud_fifo.v  --  asynchronous audio FIFO (video byte stream -> I2S)
//
//  WRITE SIDE : 100 MHz SD/SDRAM domain (m6_vdec O_aud_we/O_aud_data), one
//               16 bit mono sample per write strobe.  The audio of one video
//               frame is 3200 samples (48 kHz / 15 fps) and arrives as a short
//               burst right after the RLE payload of that frame.
//  READ SIDE  : 12.288 MHz MCLK domain, one sample per I_rd pulse, which is
//               m6_i2s_tx O_tick (once per LRCK frame).
//
//  The FIFO therefore only has to bridge one frame worth of data plus the
//  frequency drift between the 100 MHz and the 12.288 MHz PLLs, so 8192
//  entries (16 KB, 8 x BRAM9K) is far more than enough.
//
//  Gray coded pointers with 2FF synchronisers.  Both sides only move forward,
//  so no special reset handshake is required: an underrun plays silence, an
//  overflow drops the newest sample.  Both counters are exposed for bring-up.
//=============================================================================
`timescale 1ns / 10ps

module m6_aud_fifo #(
    parameter integer AW = 13           // 2**AW samples (13 -> 8192, 12 -> 4096)
) (
    // write side : 100 MHz
    input  wire        I_wclk,
    input  wire        I_wrst,      // synchronous, high active
    input  wire        I_we,
    input  wire [15:0] I_wdata,
    output wire [13:0] O_wlevel,    // entries in use (write domain, approximate)
    output wire [31:0] O_wr_cnt,    // samples written
    output wire [31:0] O_ovf_cnt,   // samples dropped because the FIFO was full

    // read side : MCLK domain
    input  wire        I_rclk,
    input  wire        I_rrst,      // synchronous, high active
    input  wire        I_rd,        // 1 cycle pulse : advance one sample
    output wire [15:0] O_rdata,     // current sample (0 while empty)
    output wire [31:0] O_unf_cnt    // sample slots played while empty
);

    localparam integer PW = AW + 1;             // pointer width

    //-------------------------------------------------------------------------
    // sample memory : inferred true dual port block RAM
    //-------------------------------------------------------------------------
    reg [15:0] S_mem [0:(1<<AW)-1];

    //-------------------------------------------------------------------------
    // pointers / counters
    //-------------------------------------------------------------------------
    // write side
    reg  [PW-1:0] S_wptr;           // binary write pointer
    reg  [PW-1:0] S_wgray;          // gray coded write pointer
    reg  [PW-1:0] S_rg_s1, S_rg_s2; // read pointer synchronised into this domain
    reg  [31:0]   S_wcnt, S_ovf;

    // read side
    reg  [PW-1:0] S_rptr;           // binary read pointer
    reg  [PW-1:0] S_rgray;          // gray coded read pointer
    reg  [PW-1:0] S_wg_s1, S_wg_s2; // write pointer synchronised into this domain
    reg  [15:0]   S_rdata;
    reg  [31:0]   S_unf;

    //-------------------------------------------------------------------------
    // gray <-> binary helpers
    //-------------------------------------------------------------------------
    function [PW-1:0] gray2bin (input [PW-1:0] g);
        integer i;
        begin
            gray2bin[PW-1] = g[PW-1];
            for (i = PW-2; i >= 0; i = i - 1)
                gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    wire [PW-1:0] S_inc_w    = S_wptr + 1'b1;
    wire [PW-1:0] S_inc_r    = S_rptr + 1'b1;
    wire [PW-1:0] S_rbin_w   = gray2bin(S_rg_s2);
    wire [PW-1:0] S_wbin_r   = gray2bin(S_wg_s2);
    wire [PW-1:0] S_wlevel   = S_wptr - S_rbin_w;

    //-------------------------------------------------------------------------
    // write side
    //-------------------------------------------------------------------------
    always @(posedge I_wclk) begin
        if (I_wrst) begin
            S_wptr  <= {PW{1'b0}};
            S_wgray <= {PW{1'b0}};
            S_rg_s1 <= {PW{1'b0}};
            S_rg_s2 <= {PW{1'b0}};
            S_wcnt  <= 32'd0;
            S_ovf   <= 32'd0;
        end else begin
            S_rg_s1 <= S_rgray;
            S_rg_s2 <= S_rg_s1;
            if (I_we) begin
                if (S_wlevel < (1 << AW)) begin
                    S_mem[S_wptr[AW-1:0]] <= I_wdata;
                    S_wptr  <= S_inc_w;
                    S_wgray <= S_inc_w ^ (S_inc_w >> 1);
                    S_wcnt  <= S_wcnt + 32'd1;
                end else
                    S_ovf <= S_ovf + 32'd1;
            end
        end
    end

    assign O_wlevel  = S_wlevel;        // zero extended to 14 bit by the port width
    assign O_wr_cnt  = S_wcnt;
    assign O_ovf_cnt = S_ovf;

    //-------------------------------------------------------------------------
    // read side
    //-------------------------------------------------------------------------
    always @(posedge I_rclk) begin
        if (I_rrst) begin
            S_rptr  <= {PW{1'b0}};
            S_rgray <= {PW{1'b0}};
            S_wg_s1 <= {PW{1'b0}};
            S_wg_s2 <= {PW{1'b0}};
            S_rdata <= 16'd0;
            S_unf   <= 32'd0;
        end else begin
            S_wg_s1 <= S_wgray;
            S_wg_s2 <= S_wg_s1;
            // block RAM output register : always points at the current sample
            S_rdata <= S_mem[S_rptr[AW-1:0]];
            if (I_rd) begin
                if (S_rptr != S_wbin_r) begin
                    S_rptr  <= S_inc_r;
                    S_rgray <= S_inc_r ^ (S_inc_r >> 1);
                end else begin
                    // underrun : keep the pointer and play silence
                    S_unf   <= S_unf + 32'd1;
                    S_rdata <= 16'd0;
                end
            end
        end
    end

    assign O_rdata   = S_rdata;
    assign O_unf_cnt = S_unf;

endmodule
