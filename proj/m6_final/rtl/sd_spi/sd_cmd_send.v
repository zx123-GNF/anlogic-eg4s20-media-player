`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:29:20
// Design Name: 
// Module Name: sd_cmd_send
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
module sd_cmd_send(
    output reg         [   7: 0]        send_dout                  ,
    output                              spi_start                  ,
    output                              idle                       ,
    output reg                          done                       ,
    input              [  47: 0]        send_din                   ,
    input                               start                      ,
    input                               spi_done                   ,
    input                               clk                        ,
    input                               rst                         
    );
    
    localparam                          IDLE                      = 0     ,
               SEND = 1;
    
    wire               [   2: 0]        cnt_value                  ;
    
    reg                                 state                      ;
    
    assign                              idle                      = state == IDLE;
    assign                              cnt_en                    = state == IDLE && start || state == SEND && (spi_done || cnt_full);
    assign                              spi_start                 = state == IDLE && start;
    
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
        case(cnt_value)
            0: send_dout <= send_din[47:40];
            1: send_dout <= send_din[39:32];
            2: send_dout <= send_din[31:24];
            3: send_dout <= send_din[23:16];
            4: send_dout <= send_din[15:8];
            5: send_dout <= send_din[7:0];
            default: send_dout <= 8'hff;
        endcase
    end
    
    cnt #(
    .dir                                (0                         ),
    .en                                 (1                         ),
    .max_value                          (7                         ) 
        ) CNT0
        (
    .cnt_value                          (cnt_value                 ),
    .full                               (cnt_full                  ),
    .cnt_en                             (cnt_en                    ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
        );
endmodule
