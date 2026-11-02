`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:30:35
// Design Name: 
// Module Name: sd_write_addr
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
module sd_write_addr #(parameter mode = 0)(
    output reg         [   7: 0]        send_dout                  ,
    output                              spi_start                  ,
    output                              idle                       ,
    output reg                          done                       ,
    input              [  31: 0]        sd_addr                    ,
    input                               start                      ,
    input                               spi_done                   ,
    input                               clk                        ,
    input                               rst                         
    );
    
    localparam                          IDLE                      = 0     ,
               SEND = 1;
    
    wire               [   3: 0]        cnt_value                  ;
    wire               [  47: 0]        write_addr                 ;
    
    reg                                 state                      ;
    
    assign                              idle                      = state == IDLE;
    assign                              cnt_en                    = state == IDLE && start || state == SEND && (spi_done || cnt_full);
    assign                              spi_start                 = state == IDLE && start;
    assign                              write_addr                = {8'h58 - mode*7,sd_addr,8'hff};
    
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
            0: send_dout <= write_addr[47:40];
            1: send_dout <= write_addr[39:32];
            2: send_dout <= write_addr[31:24];
            3: send_dout <= write_addr[23:16];
            4: send_dout <= write_addr[15:8];
            5: send_dout <= write_addr[7:0];
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
