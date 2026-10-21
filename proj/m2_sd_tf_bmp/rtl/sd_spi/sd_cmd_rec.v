`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:30:00
// Design Name: 
// Module Name: sd_cmd_rec
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
module sd_cmd_rec(
    output reg         [  39: 0]        rec_data                   ,
    output                              idle                       ,
    output reg                          done                       ,
    input              [   7: 0]        spi_rec                    ,
    input                               start                      ,
    input                               spi_done                   ,
    input                               clk                        ,
    input                               rst                         
    );
    
    localparam                          IDLE                      = 0     ,
               REC = 1;
    
    wire               [   2: 0]        cnt_value                  ;
    
    reg                                 state                      ;
    
    assign                              idle                      = state == IDLE;
    assign                              cnt_en                    = state == REC && (spi_done || cnt_full);
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            state <= IDLE;
        else if(state == IDLE && start)
            state <= REC;
        else if(state == REC && cnt_full)
            state <= IDLE;
    end
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            rec_data <= 0;
        else if(state == REC && spi_done)
        begin
            case(cnt_value)
                2: rec_data[39:32] <= spi_rec;
                3: rec_data[31:24] <= spi_rec;
                4: rec_data[23:16] <= spi_rec;
                5: rec_data[15:8] <= spi_rec;
                6: rec_data[7:0] <= spi_rec;
            endcase
        end
    end
    
    always@(posedge clk or posedge rst)
    begin
        if(rst)
            done <= 0;
        else if(state == REC && cnt_full)
            done <= 1;
        else
            done <= 0;
    end
    
    cnt #(
    .dir                                (0                         ),
    .en                                 (1                         ),
    .max_value                          (8                         ) 
        ) CNT0
        (
    .cnt_value                          (cnt_value                 ),
    .full                               (cnt_full                  ),
    .cnt_en                             (cnt_en                    ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
        );
endmodule
