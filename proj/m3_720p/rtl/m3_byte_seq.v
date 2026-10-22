//=============================================================================
//  m3_byte_seq.v
//  "read N bytes of the current 512 byte sector buffer into a register"
//
//  The 512 x 8 sector buffer lives inside the vendor SD engine
//  (sd_card_control -> RD_RAM).  Its read port is a plain synchronous RAM
//  port in the 100 MHz system clock domain:
//
//      rd_ram_dout(t+1) = RD_RAM[rd_ram_addr(t)]
//
//  so a byte is captured one clock after its address has been presented and
//  held for that clock.  The sequence is therefore
//
//      S_IDLE : latch I_off / I_cnt, O_addr <= I_off   (start pulse cycle)
//      S_PRE  : O_addr == I_off is presented to the RAM
//      S_RUN  : V[idx] <= I_din ; O_addr <= O_addr+1   (I_din == byte[I_off])
//               ... repeated I_cnt times (2 clocks per byte)
//      S_DONE : one cycle O_done, O_val valid
//
//  V[] is a NB x 8 register file with a variable write index and NB fixed read
//  slices (=> NB*8 flip-flops plus a 6-to-NB enable decoder).  Byte i of the
//  sequence is available at O_val[8*i +: 8], which makes little endian fields
//  read naturally as {byte3,byte2,byte1,byte0}.
//
//  NB = 34 bytes is exactly the widest field block this design reads (the BMP
//  header, 34 bytes); the directory entry needs 32, the partition entry 16.
//  Keeping the bus at 272 bits instead of 512 matters: the whole width is
//  routed from u_bs to u_fat every cycle and was the dominant net delay of
//  the 100 MHz domain in the first place-and-route.
//
//  Used for every field access of the FAT32 structures (MBR partition entry,
//  BPB, directory entry, FAT entry) and for the 34 byte BMP header, so the
//  main FSM never has to deal with RAM latency.
//=============================================================================
`timescale 1ns / 10ps

module m3_byte_seq (
    input  wire         I_clk,
    input  wire         I_rst,

    input  wire         I_start,        // one cycle pulse
    input  wire [8:0]   I_off,          // first byte offset inside the sector
    input  wire [5:0]   I_cnt,          // number of bytes, 1..34
    output reg          O_busy,
    output reg          O_done,         // one cycle pulse, O_val valid

    output reg  [8:0]   O_addr,         // sector buffer read address
    input  wire [7:0]   I_din,          // sector buffer read data

    output wire [271:0] O_val           // byte i -> O_val[8*i +: 8]
);

    localparam S_IDLE = 2'd0;
    localparam S_PRE  = 2'd1;
    localparam S_RUN  = 2'd2;
    localparam S_DONE = 2'd3;

    reg [1:0]  S_st;
    reg [5:0]  S_idx;
    reg [5:0]  S_cnt;
    reg [7:0]  V [0:33];

    integer i;
    genvar  gi;

    generate
        for (gi = 0; gi < 34; gi = gi + 1) begin : G_pack
            assign O_val[8*gi + 7 : 8*gi] = V[gi];
        end
    endgenerate

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_st   <= S_IDLE;
            S_idx  <= 6'd0;
            S_cnt  <= 6'd1;
            O_busy <= 1'b0;
            O_done <= 1'b0;
            O_addr <= 9'd0;
            for (i = 0; i < 34; i = i + 1)
                V[i] <= 8'h00;
        end else begin
            O_done <= 1'b0;

            case (S_st)
                S_IDLE: begin
                    O_busy <= 1'b0;
                    if (I_start) begin
                        O_addr <= I_off;
                        S_cnt  <= (I_cnt == 6'd0) ? 6'd1 : I_cnt;
                        S_idx  <= 6'd0;
                        O_busy <= 1'b1;
                        S_st   <= S_PRE;
                    end
                end

                S_PRE: begin
                    // The sector buffer RAM registers its output, so the byte
                    // seen at cycle t is mem[addr(t-1)].  O_addr was loaded
                    // with I_off in S_IDLE, which makes the first sample
                    // correct, but the address must ALSO advance during this
                    // cycle: otherwise every following sample reads one byte
                    // too early, i.e. V[1] = mem[I_off] again and the whole
                    // sequence is shifted by one.
                    //
                    // Bench symptom (UART dump of the MBR signature read at
                    // offset 510):  payload = 55 55 instead of 55 AA, the FAT
                    // partition entry was read one byte off and the BMP header
                    // would have been too.
                    O_addr <= O_addr + 9'd1;
                    S_st   <= S_RUN;
                end

                S_RUN: begin
                    V[S_idx] <= I_din;
                    O_addr   <= O_addr + 9'd1;
                    S_idx    <= S_idx + 6'd1;
                    if (({1'b0, S_idx} + 7'd1) >= {1'b0, S_cnt}) begin
                        S_st <= S_DONE;
                    end
                end

                S_DONE: begin
                    O_done <= 1'b1;
                    O_busy <= 1'b0;
                    S_st   <= S_IDLE;
                end

                default: S_st <= S_IDLE;
            endcase
        end
    end

endmodule
