`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:06:08
// Design Name: 
// Module Name: uart_sd_example
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module uart_sd_example #(parameter clock_freq = 100_000_000,baud_rate = 115200)(
    output                              mosi                       ,
    output                              sclk                       ,
    output                              cs_n                       ,
    output                              uart_tx                    ,
    input                               uart_rx                    ,
    input                               miso                       ,
    input                               clk                        ,
    input                               rst                         
    );
    
    localparam                          SD_INIT                   = 6'b000_001,
                                        IDLE                      = 6'b000_010,
                                        SAVE_UART_STR             = 6'b000_100,
                                        SD_WRITE                  = 6'b001_000,
                                        SD_READ                   = 6'b010_000,
                                        SEND_UART_STR             = 6'b100_000;
    
    wire               [  63: 0]        param_string,numberstring  ;
    wire               [  31: 0]        str_bcd                    ;
    wire               [  27: 0]        str_hex                    ;
    wire               [   8: 0]        cnt_value                  ;
    wire               [   7: 0]        uart_rx_data,uart_tx_data  ;
    wire               [   3: 0]        param_cnt                  ;
    
    reg                [  27: 0]        sector_addr                ;
    reg                [   5: 0]        state,nxt_state            ;
    reg                [   1: 0]        sd_card_mode               ;
    reg                                 uart_send_en,sd_card_run,cnt_en,cnt_rst  ;
    
    assign                              wr_ram_wea                = state == SAVE_UART_STR ? rx_rec_flag : 0;
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            state <= SD_INIT;
        else
            state <= nxt_state;
    end
    
    always@(*) begin
        case(state)
            SD_INIT:
                if(sd_card_done)
                    nxt_state <= IDLE;
                else
                    nxt_state <= SD_INIT;
            
            IDLE: begin
                if(write_equal && start)
                    nxt_state <= SAVE_UART_STR;
                else if(read_equal && start)
                    nxt_state <= SD_READ;
                else
                    nxt_state <= IDLE;
            end
            
            SAVE_UART_STR:
                if(rx_rec_flag && uart_rx_data == 0)
                    nxt_state <= SD_WRITE;
                else
                    nxt_state <= SAVE_UART_STR;
                    
            SD_WRITE:
                if(sd_card_done)
                    nxt_state <= IDLE;
                else
                    nxt_state <= SD_WRITE;
                    
            SD_READ:
                if(sd_card_done)
                    nxt_state <= SEND_UART_STR;
                else
                    nxt_state <= SD_READ;
                    
            SEND_UART_STR:
                if(uart_tx_start && uart_tx_data == 0)
                    nxt_state <= IDLE;
                else
                    nxt_state <= SEND_UART_STR;
            
            default: nxt_state <= IDLE;
        endcase
    end
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            uart_send_en <= 0;
        else if(state == SEND_UART_STR && !uart_tx_done)
            uart_send_en <= 1;
        else
            uart_send_en <= 0;
    end
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            cnt_rst <= 1;
        else if(state == IDLE && nxt_state == SAVE_UART_STR)
            cnt_rst <= 1;
        else if(state == SD_READ && nxt_state <= SEND_UART_STR)
            cnt_rst <= 1;
        else
            cnt_rst <= 0;
    end
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            cnt_en <= 0;
        else if(rx_rec_flag || uart_tx_done)
            cnt_en <= 1;
        else
            cnt_en <= 0;
    end
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            sd_card_run <= 0;
        else if(state == SD_INIT || state == SD_WRITE || state == SD_READ)
            sd_card_run <= 1;
        else
            sd_card_run <= 0;
    end
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            sd_card_mode <= 0;
        else begin
            case(state)
                SD_INIT: sd_card_mode <= 0;
                SD_WRITE: sd_card_mode <= 1;
                SD_READ: sd_card_mode <= 2;
                default: sd_card_mode <= 0;
            endcase
        end
    end
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            sector_addr <= 0;
        else if(state == IDLE && nxt_state == SAVE_UART_STR || state == IDLE && nxt_state == SD_READ)
            sector_addr <= str_hex;
    end
    
    string_save_cmp #(.byte_num(5),.byte_offset(1),.start_signal(".")) STR_CMP0(
    .str_buf                            (                          ),
    .str_cnt                            (                          ),
    .equal                              (write_equal               ),
    .greater                            (                          ),
    .less                               (                          ),
    .str_cmp                            ("write"                   ),
    .str_in                             (uart_rx_data              ),
    .rx_flag                            (rx_rec_flag               ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
        );
        
    string_save_cmp #(.byte_num(4),.byte_offset(1),.start_signal(".")) STR_CMP1(
    .str_buf                            (                          ),
    .str_cnt                            (                          ),
    .equal                              (read_equal                ),
    .greater                            (                          ),
    .less                               (                          ),
    .str_cmp                            ("read"                    ),
    .str_in                             (uart_rx_data              ),
    .rx_flag                            (rx_rec_flag               ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
        );
        
    string_param #(.byte_num(8),.start_signal("("),.end_signal(")")) STR_SAVE0(
    .str_buf                            (                          ),
    .str_rank                           (numberstring              ),
    .str_cnt                            (param_cnt                 ),
    .param_rec_done                     (param_rec_done            ),
    .str_in                             (uart_rx_data              ),
    .rx_flag                            (rx_rec_flag               ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
        );
        
        
    delay #(.max_delay_cycle(100)) DELAY0(
    .delay_done                         (start                     ),
    .delay_start                        (param_rec_done            ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
    );
        
    numstr_to_bcd #(.str_num(8)) NUMSTR_BCD0(
    .bcd                                (str_bcd                   ),
    .numstr                             (numberstring              ) 
        );
        
    bcd_to_hex #(.bcd_bit(32), .hex_bit(28)) BTH0(
    .hex                                (str_hex                   ),
    .bcd                                (str_bcd                   ) 
    );
    
    uart_const_baud #(.clock_freq(clock_freq),.baud_rate(baud_rate)) UART0(
    .rx_data                            (uart_rx_data              ),
    .rx_rec_flag                        (rx_rec_flag               ),
    .tx                                 (uart_tx                   ),
    .tx_done                            (uart_tx_done              ),
    .tx_idle                            (                          ),
    .tx_data                            (uart_tx_data              ),
    .tx_start                           (uart_tx_start             ),
    .rx                                 (uart_rx                   ),
    .rx_clr                             (rx_rec_flag               ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
    );
    
    sequence_comparator #(.width(2),.filt_sequence(2'b01)) SC0(
    .result                             (sd_card_start             ),
    .sequence_in                        (sd_card_run               ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
        );
        
    pulse_conver #(.width(2),.filt_value(2'b01)) PC0(
    .pulse_out                          (uart_tx_start             ),
    .pulse_in                           (uart_send_en              ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
        );
    
    //为了兼容低于100M主频的情况，spi_highfreq设置为clock_freq/4，如果主频clock_freq高于100M，建议设置为25_000_000
    sd_card_control #(.clock_freq(clock_freq),.spi_lowfreq(400_000),.spi_highfreq(clock_freq/4)) SD_CTRL(
    .mosi                               (mosi                      ),
    .sclk                               (sclk                      ),
    .cs_n                               (cs_n                      ),
    .idle                               (                          ),
    .done                               (sd_card_done              ),
    .rd_ram_dout                        (uart_tx_data              ),
    .rd_ram_addr                        (cnt_value                 ),
    .wr_ram_din                         (uart_rx_data              ),
    .wr_ram_addr                        (cnt_value                 ),
    .wr_ram_wea                         (wr_ram_wea                ),
    .sector_addr                        (sector_addr               ),
    .miso                               (miso                      ),
    .start                              (sd_card_start             ),
    .mode                               (sd_card_mode              ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
        );
    
    cnt #(
    .dir                                (0                         ),
    .en                                 (1                         ),
    .max_value                          (512                       ) 
        ) CNT0
        (
    .cnt_value                          (cnt_value                 ),
    .cnt_en                             (cnt_en                    ),
    .clk                                (clk                       ),
    .rst                                (cnt_rst                   ) 
        );
endmodule
