`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:32:28
// Design Name: 
// Module Name: sd_read_data
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
module sd_read_data(
    output reg         [   7: 0]        rec_data                   ,
    output reg         [   8: 0]        ram_addr                   ,
    output reg                          ram_en                     ,
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
    
    wire               [   9: 0]        cnt_value                  ;
    
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
        if(rst) begin
            rec_data <= 0;
            ram_addr <= 0;
            ram_en <= 0;
        end
        else if(state == REC && spi_done && cnt_value < 512)
        begin
            rec_data <= spi_rec;
            ram_addr <= cnt_value;
            ram_en <= 1;
        end
        else
            ram_en <= 0;
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
    .max_value                          (515                       ) 
        ) CNT0
        (
    .cnt_value                          (cnt_value                 ),
    .full                               (cnt_full                  ),
    .cnt_en                             (cnt_en                    ),
    .clk                                (clk                       ),
    .rst                                (rst                       ) 
        );
endmodule
