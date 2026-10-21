`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:31:04
// Design Name: 
// Module Name: sd_write_data
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
module sd_write_data(
    output reg         [   7: 0]        send_dout                  ,
    output             [   8: 0]        ram_addr                   ,
    output                              spi_start                  ,
    output                              idle                       ,
    output reg                          done                       ,
    input              [   7: 0]        ram_data                   ,
    input                               start                      ,
    input                               spi_done                   ,
    input                               clk                        ,
    input                               rst                         
    );
    
    localparam                          IDLE                      = 0     ,
               SEND = 1;
    
    wire               [   9: 0]        cnt_value                  ;
    wire               [  79: 0]        write_addr                 ;
    
    reg                                 state                      ;
    
    assign                              idle                      = state == IDLE;
    assign                              cnt_en                    = state == IDLE && start || state == SEND && (spi_done || cnt_full);
    assign                              spi_start                 = state == IDLE && start;
    assign                              ram_addr                  = cnt_value - 1;
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            state <= IDLE;
        else if(state == IDLE && start)
            state <= SEND;
        else if(state == SEND && cnt_full)
            state <= IDLE;
    end
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            done <= 0;
        else if(state == SEND && cnt_full)
            done <= 1;
        else
            done <= 0;
    end
    
    always@(*) begin
        if(cnt_value > 512)
            send_dout <= 8'hff;
        else if(cnt_value == 0)
            send_dout <= 8'hfe;
        else
            send_dout <= ram_data;
    end
    
    cnt #(
    .dir                                (0                         ),
    .en                                 (1                         ),
    .max_value                          (518                       ) 
        ) CNT0
        (
    .cnt_value                          (cnt_value                 ),
    .full                               (cnt_full                  ),
    .cnt_en                             (cnt_en                    ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
        );
endmodule
