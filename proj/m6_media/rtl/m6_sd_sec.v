//=============================================================================
//  m6_sd_sec.v
//  Thin wrapper around the vendor SD-card SPI engine  (sd_card_control.v,
//  copied byte-for-byte from the AC208 example 02-uart_sd_rw).
//
//  The vendor module already is exactly what M2 needs:
//
//      start / busy(idle) / done   one transaction = one 512 byte sector
//      mode = 0  CMD0/CMD8/CMD55/ACMD41 initialisation, 400 kHz
//      mode = 1  write sector (CMD24) -- unused here
//      mode = 2  read  sector (CMD17), 25 MHz, into the internal 512x8 RD_RAM
//      rd_ram_addr / rd_ram_dout   read port of that buffer (system clock)
//
//  What this wrapper adds:
//    * a one cycle start pulse with the LBA latched one cycle earlier, so the
//      engine sees a stable sector_addr when it samples start;
//    * a WATCHDOG.  Without a card (or with a card that never answers) the
//      vendor FSM waits forever for the R1 response / 0xFE data token and
//      sd_init loops on CMD0.  A timeout resets the engine (its rst is a
//      global asynchronous reset) and reports O_err, which lets the FAT layer
//      fall back to the M1 test pattern instead of hanging the screen;
//    * a 10 ms power-on delay counter is *not* here, it lives in the FSM.
//
//  Timeout budget (100 MHz):
//      sector read  ~190 us  ->  2^22 clocks = 41.9 ms   (220x margin)
//      card init    ~10..300 ms -> 2^28 clocks = 2.68 s  (spec allows 1 s)
//=============================================================================
`timescale 1ns / 10ps

module m6_sd_sec (
    input  wire        I_clk,           // 100 MHz
    input  wire        I_rst,           // active high

    input  wire        I_init,          // 1 = card init command, 0 = read sector
    input  wire        I_start,         // one cycle pulse
    input  wire [31:0] I_lba,           // sector address (28 bit used)
    output reg         O_busy,
    output reg         O_done,          // one cycle pulse
    output reg         O_err,           // one cycle pulse on timeout

    input  wire [8:0]  I_ram_addr,      // sector buffer read address
    output wire [7:0]  O_ram_dout,      // sector buffer read data

    // SD card pins
    output wire        O_sd_clk,
    output wire        O_sd_mosi,
    output wire        O_sd_cs_n,
    input  wire        I_sd_miso
);

    localparam S_IDLE = 2'd0;
    localparam S_GO   = 2'd1;
    localparam S_RUN  = 2'd2;
    localparam S_RST  = 2'd3;       // reset the vendor engine before every op

    reg [1:0]  S_st;
    reg [2:0]  S_rcnt;
    reg        S_init_q;
    reg [31:0] S_lba_q;
    reg [28:0] S_wd;
    reg        S_rst_sd;

    wire S_sd_done;
    wire S_sd_idle;
    wire S_start_pulse = (S_st == S_GO);

    wire [28:0] S_wd_limit = S_init_q ? 29'h0FFFFFFF     // 2^28-1 = 2.68 s
                                      : 29'h003FFFFF;    // 2^22-1 = 41.9 ms

    always @(posedge I_clk) begin
        if (I_rst) begin
            S_st     <= S_IDLE;
            S_init_q <= 1'b0;
            S_lba_q  <= 32'd0;
            S_wd     <= 29'd0;
            S_rst_sd <= 1'b0;
            O_busy   <= 1'b0;
            O_done   <= 1'b0;
            O_err    <= 1'b0;
        end else begin
            O_done   <= 1'b0;
            O_err    <= 1'b0;
            S_rst_sd <= 1'b0;

            case (S_st)
                S_IDLE: begin
                    O_busy <= 1'b0;
                    if (I_start) begin
                        S_init_q <= I_init;
                        S_lba_q  <= I_lba;
                        S_wd     <= 29'd0;
                        S_rcnt   <= 3'd0;
                        S_st     <= S_RST;
                    end
                end

                // The vendor engine must be reset before EVERY transaction.
                // Its byte counter (cnt inside sd_read_data) is cleared only by
                // rst, never by 'start', so from the second sector read on the
                // bytes are written to wrapping addresses: the MBR read (the
                // first one after reset) is correct, the BPB read back is
                // garbage.  Bench symptom via the debug UART: MBR signature ok
                // (55 AA), partition entry ok (type 0C, LBA 2048) but the BPB
                // read at offset 11 returned 80 00 22 04 ... instead of 00 02.
                S_RST: begin
                    S_rst_sd <= 1'b1;
                    if (S_rcnt == 3'd7) begin
                        S_rst_sd <= 1'b0;
                        S_st     <= S_GO;
                    end else
                        S_rcnt <= S_rcnt + 3'd1;
                end

                S_GO: begin
                    O_busy <= 1'b1;
                    S_st   <= S_RUN;
                end

                S_RUN: begin
                    if (S_sd_done) begin
                        O_busy <= 1'b0;
                        O_done <= 1'b1;
                        S_st   <= S_IDLE;
                    end else if (S_wd >= S_wd_limit) begin
                        // abort the transaction: the vendor FSM has no abort
                        O_busy   <= 1'b0;
                        O_err    <= 1'b1;
                        S_rst_sd <= 1'b1;
                        S_st     <= S_IDLE;
                    end else begin
                        S_wd <= S_wd + 29'd1;
                    end
                end

                default: S_st <= S_IDLE;
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // the vendor engine, instantiated unchanged
    //-------------------------------------------------------------------------
    sd_card_control #(
        .clock_freq  (100_000_000),
        .spi_lowfreq (400_000),
        //  M6 runs the card at 12.5 MHz instead of M5's 5 MHz.
        //
        //  WHY NOT 25 MHz (the vendor default): inside sd_card_control the
        //  spi_driver samples MISO one divided clock after SCLK moves, and at
        //  25 MHz that is 20 ns - less than the card's output delay plus the
        //  board flight time - so every sector came back shifted and the MBR
        //  read "succeeded" with garbage partition entries (M5 bench symptom:
        //  error 7).  At 5 MHz the margin is 100 ns and everything was clean.
        //
        //  M6 needs more than 5 MHz: the real world clips encode to ~34 kB of
        //  RLE payload per 15 fps frame plus 6.2 kB of audio = 610 kB/s, while
        //  5 MHz SPI tops out at ~500 kB/s measured.  10 MHz doubles the wire
        //  rate and still leaves 50 ns of setup margin for the card's output
        //  delay, i.e. the same margin ratio the 5 MHz build had.  Measured
        //  sector time 820 us -> 410 us.
        //
        //  If a card ever proves marginal here, change this one number back to
        //  5_000_000 and re-encode the clips at 6 fps (tools/m6_encode.py
        //  --fps 6): everything else in the design is rate agnostic.
        .spi_highfreq(12_500_000)
    ) u_sd (
        .mosi        (O_sd_mosi),
        .sclk        (O_sd_clk),
        .cs_n        (O_sd_cs_n),
        .idle        (S_sd_idle),
        .done        (S_sd_done),

        .rd_ram_dout (O_ram_dout),
        .rd_ram_addr (I_ram_addr),

        .wr_ram_din  (8'd0),
        .wr_ram_addr (9'd0),
        .wr_ram_wea  (1'b0),

        .sector_addr (S_lba_q[27:0]),
        .miso        (I_sd_miso),
        .start       (S_start_pulse),
        .mode        (S_init_q ? 2'd0 : 2'd2),

        .clk         (I_clk),
        .rst         (I_rst | S_rst_sd)
    );

endmodule
