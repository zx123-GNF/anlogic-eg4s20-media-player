`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:33:15
// Design Name: 
// Module Name: spi_driver
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
//sclk输出为二分之一的clk，所以设置spi速率公式：clk = sclk*2
//该spi通信模块为八位传输，但支持通过设置next端口为1来连发，从而达到一次性传输多位的效果
//mode用于调节四种模式，这四种模式如下：
//Mode 0: CPOL = 0, CPHA = 0
//Mode 1: CPOL = 0, CPHA = 1
//Mode 2: CPOL = 1, CPHA = 0
//Mode 3: CPOL = 1, CPHA = 1
module spi_driver(
    output reg         [   7: 0]        rec_data                   ,
    output reg                          mosi                       ,
    output reg                          sclk                       ,
    output                              idle                       ,
    output reg                          done                       ,
    input              [   7: 0]        send_data                  ,
    input                               miso                       ,
    input              [   1: 0]        mode                       ,
    input                               start                      ,
    input                               next                       ,
    input                               clk                        ,
    input                               rst                         
    );
    
    localparam                          IDLE                      = 0     ,
               WORK = 1;
    
    wire               [   3: 0]        cnt_value                  ;
    
    reg                                 state                      ;
    reg                [   7: 0]        shift_reg                  ;
    
    assign                              idle                      = state == IDLE;
    assign                              cnt_en                    = state == WORK;
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            state <= IDLE;
        else if(state == IDLE && start)
            state <= WORK;
        else if(state == WORK && cnt_done && !next)
            state <= IDLE;
    end
    
    always@(posedge clk or posedge rst)
    begin
        if(rst) begin
            done <= 0;
            rec_data <= 0;
        end
        else if(state == WORK && cnt_done) begin
            done <= 1;
            if(mode[0])
                rec_data <= {shift_reg[6:0],miso};
            else
                rec_data <= shift_reg;
        end
        else
            done <= 0;
    end
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            mosi <= 1;
        else if(state == IDLE) begin
            if(!mode[0] && start)
                mosi <= send_data[7];
            else
                mosi <= 1;
        end
        else if(state == WORK && mode[0] ^ cnt_value[0])
        begin
            if(cnt_done)
                mosi <= send_data[7];
            else
                mosi <= shift_reg[7];
        end
    end
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            shift_reg <= 0;
        else if(state == IDLE)
            shift_reg <= send_data;
        else if(state == WORK && cnt_done)
            shift_reg <= send_data;
        else if(state == WORK && mode[0] == cnt_value[0])
            shift_reg <= {shift_reg[6:0],miso};
    end
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            sclk <= 0;
        else if(state == IDLE)
            sclk <= mode[1];
        else if(state == WORK) begin
            if(cnt_value[0])
                sclk <= mode[1];
            else
                sclk <= ~mode[1];
        end
    end
    
    cnt #(
    .dir                                (0                         ),
    .en                                 (1                         ),
    .max_value                          (16                        ) 
        ) CNT0
        (
    .cnt_value                          (cnt_value                 ),
    .done                               (cnt_done                  ),
    .cnt_en                             (cnt_en                    ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
        );
endmodule
