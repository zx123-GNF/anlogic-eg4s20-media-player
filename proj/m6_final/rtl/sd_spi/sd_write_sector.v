`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:28:00
// Design Name: 
// Module Name: sd_write_sector
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
module sd_write_sector(
    output reg         [   7: 0]        spi_send_data              ,
    output             [   8: 0]        ram_addr                   ,
    output reg                          spi_start                  ,
    output reg                          spi_next                   ,
    output reg                          cs_n                       ,
    output                              idle                       ,
    output reg                          done                       ,
    input              [  27: 0]        sector_addr                ,
    input              [   7: 0]        spi_rec_data               ,
    input              [   7: 0]        ram_data                   ,
    input                               spi_done                   ,
    input                               start                      ,
    input                               clk                        ,
    input                               rst                         
    );
    
    localparam                          IDLE                      = 0     ,
                                        WR_ADDR                   = 1     ,
                                        WAIT_REC                  = 2     ,
                                        WAIT_GAP                  = 3     ,
                                        WR_DATA                   = 4     ,
                                        WAIT_BUSY                 = 5     ,
                                        WAIT_IDLE                 = 6     ,
                                        FINISH                    = 7     ;
    
    wire               [   7: 0]        addr_send_dout,data_send_dout  ;
    
    reg                [   2: 0]        state                      ;
    
    assign                              idle                      = state == IDLE;
    assign                              addr_start                = state == WR_ADDR;
    assign                              data_start                = state == WR_DATA;
    
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
                        state <= WAIT_GAP;
                WAIT_GAP:
                    if(spi_done)
                        state <= WR_DATA;
                WR_DATA:
                    if(wr_data_done)
                        state <= WAIT_BUSY;
                WAIT_BUSY:
                    if(spi_rec_data == 8'h00)
                        state <= WAIT_IDLE;
                WAIT_IDLE:
                    if(spi_rec_data == 8'hff)
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
        else if(state == WR_DATA) begin
            spi_send_data <= data_send_dout;
            spi_start <= data_spi_start;
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
            WAIT_GAP: spi_next = 0;
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
    
    sd_write_addr SD_WR_ADDR(
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
    
    sd_write_data SD_WR_DATA(
    .send_dout                          (data_send_dout            ),
    .ram_addr                           (ram_addr                  ),
    .spi_start                          (data_spi_start            ),
    .idle                               (                          ),
    .done                               (wr_data_done              ),
    .ram_data                           (ram_data                  ),
    .start                              (data_start_pulse          ),
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
    .result                             (data_start_pulse          ),
    .sequence_in                        (data_start                ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
        );
endmodule
