`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:25:16
// Design Name: 
// Module Name: sd_init
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
module sd_init(
    output reg         [   7: 0]        spi_send_data              ,
    output                              spi_start                  ,
    output reg                          spi_next                   ,
    output reg                          cs_n                       ,
    output                              idle                       ,
    output reg                          done                       ,
    input              [   7: 0]        spi_rec_data               ,
    input                               spi_done                   ,
    input                               start                      ,
    input                               clk                        ,
    input                               rst                         
    );
    
    localparam                          CMD0                      = {8'h40,8'h00,8'h00,8'h00,8'h00,8'h95},
                                        CMD8                      = {8'h48,8'h00,8'h00,8'h01,8'haa,8'h87},
                                        CMD55                     = {8'h77,8'h00,8'h00,8'h00,8'h00,8'hff},
                                        ACMD41                    = {8'h69,8'h40,8'h00,8'h00,8'h00,8'hff};
    
    localparam                          IDLE                      = 0     ,
                                        SEND_FIRST                = 1     ,
                                        REC_FIRST                 = 2     ,
                                        WAIT_SPI                  = 3     ,
                                        SEND_CMD0                 = 4     ,
                                        REC_CMD0                  = 5     ,
                                        CHECK_CMD0                = 6     ,
                                        SEND_CMD8                 = 7     ,
                                        REC_CMD8                  = 8     ,
                                        CHECK_CMD8                = 9     ,
                                        SEND_CMD55                = 10    ,
                                        REC_CMD55                 = 11    ,
                                        CHECK_CMD55               = 12    ,
                                        SEND_ACMD41               = 13    ,
                                        REC_ACMD41                = 14    ,
                                        CHECK_ACMD41              = 15    ;
    
    wire               [  39: 0]        rec_data                   ;
    wire               [   7: 0]        send_dout                  ;
    
    reg                [   3: 0]        state                      ;
    
    reg                                 send_start,rec_start       ;
    reg                [  47: 0]        send_din                   ;
    
    assign                              idle                      = state == IDLE;
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            state <= IDLE;
        else begin
            case(state)
                IDLE:
                    if(start)
                        state <= SEND_FIRST;
                SEND_FIRST:
                    if(send_done)
                        state <= REC_FIRST;
                REC_FIRST:
                    if(rec_done)
                        state <= WAIT_SPI;
                WAIT_SPI:
                    if(spi_done)
                        state <= SEND_CMD0;
                SEND_CMD0:
                    if(send_done)
                        state <= REC_CMD0;
                REC_CMD0:
                    if(rec_done)
                        state <= CHECK_CMD0;
                CHECK_CMD0:
                    if(spi_done) begin
                        if(rec_data[39:32] == 8'h01)
                            state <= SEND_CMD8;
                        else
                            state <= SEND_FIRST;
                    end
                SEND_CMD8:
                    if(send_done)
                        state <= REC_CMD8;
                REC_CMD8:
                    if(rec_done)
                        state <= CHECK_CMD8;
                CHECK_CMD8:
                    if(spi_done) begin
                        if(rec_data[11:8] == 4'h1)
                            state <= SEND_CMD55;
                        else
                            state <= SEND_FIRST;
                    end
                SEND_CMD55:
                    if(send_done)
                        state <= REC_CMD55;
                REC_CMD55:
                    if(rec_done)
                        state <= CHECK_CMD55;
                CHECK_CMD55:
                    if(spi_done) begin
                        if(rec_data[39:32] == 8'h01)
                            state <= SEND_ACMD41;
                        else
                            state <= SEND_CMD55;
                    end
                SEND_ACMD41:
                    if(send_done)
                        state <= REC_ACMD41;
                REC_ACMD41:
                    if(rec_done)
                        state <= CHECK_ACMD41;
                CHECK_ACMD41:
                    if(spi_done) begin
                        if(rec_data[39:32] == 8'h00)
                            state <= IDLE;
                        else
                            state <= SEND_CMD55;
                    end
                default:state <= IDLE;
            endcase
        end
    end
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            done <= 0;
        else if(state == CHECK_ACMD41 && spi_done && rec_data[39:32] == 8'h00)
            done <= 1;
        else
            done <= 0;
    end
    
    always@(*)
    begin
        case(state)
            SEND_FIRST:begin
                spi_send_data <= 8'hff;
                send_start <= 1;
                send_din <= 48'hffffffffffff;
            end
            SEND_CMD0: begin
                spi_send_data <= send_dout;
                send_start <= 1;
                send_din <= CMD0;
            end
            SEND_CMD8: begin
                spi_send_data <= send_dout;
                send_start <= 1;
                send_din <= CMD8;
            end
            SEND_CMD55: begin
                spi_send_data <= send_dout;
                send_start <= 1;
                send_din <= CMD55;
            end
            SEND_ACMD41: begin
                spi_send_data <= send_dout;
                send_start <= 1;
                send_din <= ACMD41;
            end
            default: begin
                spi_send_data <= 8'hff;
                send_start <= 0;
                send_din <= 48'hffffffffffff;
            end
        endcase
    end
    
    always@(*) begin
        case(state)
            REC_FIRST: rec_start <= 1;
            REC_CMD0: rec_start <= 1;
            REC_CMD8: rec_start <= 1;
            REC_CMD55: rec_start <= 1;
            REC_ACMD41: rec_start <= 1;
            default: rec_start <= 0;
        endcase
    end
    
    always@(*) begin
        case(state)
            IDLE: spi_next <= 0;
            WAIT_SPI: spi_next <= 0;
            CHECK_CMD0: spi_next <= 0;
            CHECK_CMD8: spi_next <= 0;
            CHECK_CMD55: spi_next <= 0;
            CHECK_ACMD41: spi_next <= 0;
            default: spi_next <= 1;
        endcase
    end
    
    always@(*) begin
        case(state)
            IDLE: cs_n <= 1;
            SEND_FIRST: cs_n <= 1;
            REC_FIRST: cs_n <= 1;
            WAIT_SPI: cs_n <= 1;
            CHECK_CMD0: cs_n <= 1;
            CHECK_CMD8: cs_n <= 1;
            CHECK_CMD55: cs_n <= 1;
            CHECK_ACMD41: cs_n <= 1;
            default: cs_n <= 0;
        endcase
    end
    
    sd_cmd_send SD_CMD_SEND(
    .send_dout                          (send_dout                 ),
    .spi_start                          (spi_start                 ),
    .idle                               (                          ),
    .done                               (send_done                 ),
    .send_din                           (send_din                  ),
    .start                              (send_start_pulse          ),
    .spi_done                           (spi_done                  ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
        );
    
    sd_cmd_rec SD_CMD_REC(
    .rec_data                           (rec_data                  ),
    .idle                               (                          ),
    .done                               (rec_done                  ),
    .spi_rec                            (spi_rec_data              ),
    .start                              (rec_start_pulse           ),
    .spi_done                           (spi_done                  ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
        );
        
    sequence_comparator #(.width(2),.filt_sequence(2'b01)) SC0(
    .result                             (send_start_pulse          ),
    .sequence_in                        (send_start                ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
        );
        
    sequence_comparator #(.width(2),.filt_sequence(2'b01)) SC1(
    .result                             (rec_start_pulse           ),
    .sequence_in                        (rec_start                 ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
        );
endmodule
