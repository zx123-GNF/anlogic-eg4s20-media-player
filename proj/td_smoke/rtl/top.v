`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/07/25 09:00:11
// Design Name: 
// Module Name: top
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

module top(
    output                                  mosi                                    ,
    output                                  sclk                                    ,
    output                                  sd_cs_n                                 ,
    output                                  uart_tx                                 ,
    input                                   uart_rx                                 ,
    input                                   miso                                    ,
    input                                   clk                                     ,
    input                                   rst_n                                    
);
    
    
    wire                               clk_100m                                   ;
    wire                               rst                                        ;
    assign                              rst                         = ~rst_n               ;
    
      pll pll_inst
   (
    // Clock out ports
    .clk0_out                           (clk_100m                            ),// output clk_out1
    .reset                              (rst                                 ),

   // Clock in ports
    .refclk                             (clk)                                );



    uart_sd_example #(.clock_freq(100_000_000),.baud_rate(115200)) UART_SD(
    .mosi                               (mosi                                ),
    .sclk                               (sclk                                ),
    .cs_n                               (sd_cs_n                             ),
    .uart_tx                            (uart_tx                             ),
    .uart_rx                            (uart_rx                             ),
    .miso                               (miso                                ),
    .clk                                (clk_100m                            ),
    .rst                                (rst                                 ) 
    );
        
endmodule
