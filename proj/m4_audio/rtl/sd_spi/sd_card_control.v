`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:24:20
// Design Name: 
// Module Name: sd_card_control
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
//mode: 0 ��ʼ��SD��,1 ��WR_RAM����д�뵽һ��ָ��������2 ����һ��ָ���������ݵ�RD_RAM��
module sd_card_control #(
    parameter                           clock_freq                = 100_000_000,
               spi_lowfreq = 400_000,
               spi_highfreq = 25_000_000,
               spi_low_div = clock_freq / (spi_lowfreq * 2),
               spi_high_div = clock_freq / (spi_highfreq * 2),
               spi_div_width = spi_low_div > 0 ? $clog2(spi_low_div) : 1
    )(
    output                              mosi                       ,
    output                              sclk                       ,
    output reg                          cs_n                       ,
    output                              idle                       ,
    output reg                          done                       ,
    output             [   7: 0]        rd_ram_dout                ,
    input              [   8: 0]        rd_ram_addr                ,
    input              [   7: 0]        wr_ram_din                 ,
    input              [   8: 0]        wr_ram_addr                ,
    input                               wr_ram_wea                 ,
    input              [  27: 0]        sector_addr                ,
    input                               miso                       ,
    input                               start                      ,
    input              [   1: 0]        mode                       ,
    input                               clk                        ,
    input                               rst                         
    );
    
    localparam                          IDLE                      = 4     ,
               INIT = 0,
               WR_SECTOR = 1,
               RD_SECTOR = 2,
               WAIT_IDLE = 3;
               
    wire               [   8: 0]        wr_sec_ram_addr,rd_sec_ram_addr  ;
    wire               [   7: 0]        wr_sec_ram_din,rd_sec_ram_dout  ;
    wire               [   7: 0]        spi_rec_data,init_send_data,wr_send_data,rd_send_data  ;
    wire                                init_start,wr_start,rd_start  ;
    
    reg                [   7: 0]        spi_send_data              ;
    reg                                 spi_start,spi_next         ;
    reg                                 select_idle                ;
    reg                [   1: 0]        select_num                 ;
    reg                [   2: 0]        state,nxt_state            ;
    reg                [spi_div_width-1: 0]spi_div_value           ;
    
    assign                              idle                      = state == IDLE;
    assign                              init_start                = state == INIT;
    assign                              wr_start                  = state == WR_SECTOR;
    assign                              rd_start                  = state == RD_SECTOR;
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            state <= IDLE;
        else
            state <= nxt_state;
    end
    
    always@(*) begin
        case(state)
            IDLE:
                if(start)
                    nxt_state <= mode;
                else
                    nxt_state <= IDLE;
            
            INIT:
                if(!init_idle)
                    nxt_state <= WAIT_IDLE;
                else
                    nxt_state <= INIT;
            
            WR_SECTOR:
                if(!wr_sec_idle)
                    nxt_state <= WAIT_IDLE;
                else
                    nxt_state <= WR_SECTOR;
            
            RD_SECTOR:
                if(!rd_sec_idle)
                    nxt_state <= WAIT_IDLE;
                else
                    nxt_state <= RD_SECTOR;
            
            WAIT_IDLE:
                if(select_idle)
                    nxt_state <= IDLE;
                else
                    nxt_state <= WAIT_IDLE;
            
            default: nxt_state <= IDLE;
        endcase
    end
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            done <= 0;
        else if(state == WAIT_IDLE && nxt_state == IDLE)
            done <= 1;
        else
            done <= 0;
    end
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            select_num <= 0;
        else if(state == IDLE)
            select_num <= nxt_state[1:0];
    end
    
    always@(*) begin
        case(select_num)
            INIT: begin
                select_idle <= init_idle;
                spi_div_value <= spi_low_div;
                spi_send_data <= init_send_data;
                spi_start <= init_spi_start;
                spi_next <= init_spi_next;
                cs_n <= init_cs_n;
                spi_div_value <= spi_low_div;
            end
            
            WR_SECTOR: begin
                select_idle <= wr_sec_idle;
                spi_div_value <= spi_high_div;
                spi_send_data <= wr_send_data;
                spi_start <= wr_spi_start;
                spi_next <= wr_spi_next;
                cs_n <= wr_cs_n;
            end
            
            RD_SECTOR: begin
                select_idle <= rd_sec_idle;
                spi_div_value <= spi_high_div;
                spi_send_data <= rd_send_data;
                spi_start <= rd_spi_start;
                spi_next <= rd_spi_next;
                cs_n <= rd_cs_n;
            end
            
            default: begin
                select_idle <= init_idle;
                spi_div_value <= spi_low_div;
                spi_send_data <= init_send_data;
                spi_start <= init_spi_start;
                spi_next <= init_spi_next;
                cs_n <= init_cs_n;
            end
        endcase
    end
    
    sd_init SD_INIT(
    .spi_send_data                      (init_send_data            ),
    .spi_start                          (init_spi_start            ),
    .spi_next                           (init_spi_next             ),
    .cs_n                               (init_cs_n                 ),
    .idle                               (init_idle                 ),
    .done                               (                          ),
    .spi_rec_data                       (spi_rec_data              ),
    .spi_done                           (spi_done                  ),
    .start                              (init_start                ),
    .clk                                (spi_clk                   ),
    .rst                                (rst                       ) 
        );
        
    sd_write_sector SD_WR_SEC(
    .spi_send_data                      (wr_send_data              ),
    .ram_addr                           (wr_sec_ram_addr           ),
    .spi_start                          (wr_spi_start              ),
    .spi_next                           (wr_spi_next               ),
    .cs_n                               (wr_cs_n                   ),
    .idle                               (wr_sec_idle               ),
    .done                               (                          ),
    .sector_addr                        (sector_addr               ),
    .spi_rec_data                       (spi_rec_data              ),
    .ram_data                           (wr_sec_ram_din            ),
    .spi_done                           (spi_done                  ),
    .start                              (wr_start                  ),
    .clk                                (spi_clk                   ),
    .rst                                (rst                       ) 
        );
        
    sd_read_sector SD_RD_SEC(
    .spi_send_data                      (rd_send_data              ),
    .ram_addr                           (rd_sec_ram_addr           ),
    .ram_data                           (rd_sec_ram_dout           ),
    .ram_en                             (rd_sec_ram_wea            ),
    .spi_start                          (rd_spi_start              ),
    .spi_next                           (rd_spi_next               ),
    .cs_n                               (rd_cs_n                   ),
    .idle                               (rd_sec_idle               ),
    .done                               (                          ),
    .sector_addr                        (sector_addr               ),
    .spi_rec_data                       (spi_rec_data              ),
    .spi_done                           (spi_done                  ),
    .start                              (rd_start                  ),
    .clk                                (spi_clk                   ),
    .rst                                (rst                       ) 
        );
    
    spi_driver SPI(
    .rec_data                           (spi_rec_data              ),
    .mosi                               (mosi                      ),
    .sclk                               (sclk                      ),
    .idle                               (                          ),
    .done                               (spi_done                  ),
    .send_data                          (spi_send_data             ),
    .miso                               (miso                      ),
    .mode                               (2'b11                     ),
    .start                              (spi_start                 ),
    .next                               (spi_next                  ),
    .clk                                (spi_clk                   ),
    .rst                                (rst                       ) 
        );
    
    ram_dual_port_simple #(.data_width(8),.data_num(512)) WR_RAM(
    .douta                              (                          ),
    .doutb                              (wr_sec_ram_din            ),
    .dina                               (wr_ram_din                ),
    .addra                              (wr_ram_addr               ),
    .addrb                              (wr_sec_ram_addr           ),
    .wea                                (wr_ram_wea                ),
    .clka                               (clk                       ),
    .clkb                               (spi_clk                   ) 
        );
        
    ram_dual_port_simple #(.data_width(8),.data_num(512)) RD_RAM(
    .douta                              (                          ),
    .doutb                              (rd_ram_dout               ),
    .dina                               (rd_sec_ram_dout           ),
    .addra                              (rd_sec_ram_addr           ),
    .addrb                              (rd_ram_addr               ),
    .wea                                (rd_sec_ram_wea            ),
    .clka                               (spi_clk                   ),
    .clkb                               (clk                       ) 
        );
    
    clk_div_var #(.div_width(spi_div_width),.one_allow(0)) SPI_CLK(
    .clk_out                            (spi_clk                   ),
    .div_value                          (spi_div_value             ),
    .clk_in                             (clk                       ),
    .rst                                (rst                       ) 
        );
endmodule
