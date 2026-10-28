`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:31:46
// Design Name: 
// Module Name: sd_read_sector
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
module sd_read_sector(
    output reg         [   7: 0]        spi_send_data              ,
    output             [   8: 0]        ram_addr                   ,
    output             [   7: 0]        ram_data                   ,
    output                              ram_en                     ,
    output reg                          spi_start                  ,
    output reg                          spi_next                   ,
    output reg                          cs_n                       ,
    output                              idle                       ,
    output reg                          done                       ,
    input              [  27: 0]        sector_addr                ,
    input              [   7: 0]        spi_rec_data               ,
    input                               spi_done                   ,
    input                               start                      ,
    input                               clk                        ,
    input                               rst                         
    );
    
    localparam                          IDLE                      = 0     ,
               WR_ADDR = 1,
               WAIT_REC = 2,
               WAIT_READ_START = 3,
               RD_DATA = 4,
               FINISH = 5;
    
    wire               [   7: 0]        addr_send_dout,read_send_dout  ;
    
    reg                [   2: 0]        state                      ;
    
    assign                              idle                      = state == IDLE;
    assign                              addr_start                = state == WR_ADDR;
    assign                              read_start                = state == RD_DATA;
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            state <= IDLE;
        else begin
            case(state)
                IDLE:
                    if(start)
                        state <= WR_ADDR;
                WR_ADDR:
                    if(wr_addr_done)
                        state <= WAIT_REC;
                WAIT_REC:
                    if(spi_rec_data == 8'h00)
                        state <= WAIT_READ_START;
                WAIT_READ_START:
                    if(spi_rec_data == 8'hfe)
                        state <= RD_DATA;
                RD_DATA:
                    if(rd_data_done)
                        state <= FINISH;
                FINISH:
                    if(spi_done)
                        state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            done <= 0;
        else if(state == FINISH && spi_done)
            done <= 1;
        else
            done <= 0;
    end
    
    always@(*) begin
        if(state == WR_ADDR) begin
            spi_send_data <= addr_send_dout;
            spi_start <= addr_spi_start;
        end
        else begin
            spi_send_data <= 8'hff;
            spi_start <= 0;
        end
    end
    
    always@(*)
    begin
        case(state)
            IDLE: spi_next = 0;
            FINISH: spi_next = 0;
            default: spi_next = 1;
        endcase
    end
    
    always@(*)
    begin
        case(state)
            IDLE: cs_n = 1;
            FINISH: cs_n = 1;
            default: cs_n = 0;
        endcase
    end
    
    sd_write_addr #(.mode(1)) SD_WR_ADDR(
    .send_dout                          (addr_send_dout            ),
    .spi_start                          (addr_spi_start            ),
    .idle                               (                          ),
    .done                               (wr_addr_done              ),
    .sd_addr                            (sector_addr               ),
    .start                              (addr_start_pulse          ),
    .spi_done                           (spi_done                  ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
        );
    
    sd_read_data SD_RD_DATA(
    .rec_data                           (ram_data                  ),
    .ram_addr                           (ram_addr                  ),
    .ram_en                             (ram_en                    ),
    .idle                               (                          ),
    .done                               (rd_data_done              ),
    .start                              (read_start_pulse          ),
    .spi_rec                            (spi_rec_data              ),
    .spi_done                           (spi_done                  ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
        );
        
    sequence_comparator #(.width(2),.filt_sequence(2'b01)) SC0(
    .result                             (addr_start_pulse          ),
    .sequence_in                        (addr_start                ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
        );
        
    sequence_comparator #(.width(2),.filt_sequence(2'b01)) SC1(
    .result                             (read_start_pulse          ),
    .sequence_in                        (read_start                ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
        );
endmodule
