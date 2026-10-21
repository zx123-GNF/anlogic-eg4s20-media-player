module audio_loop_back(
    clk,
    clk_18_3,
    rst_n,
//	i2c_sdat,
//	i2c_sclk,
    iis_scl,
    iis_i,
    iis_o,
    iis_oe,
    iis_done,
    aud_adclrck,
    aud_adcdat,
    aud_daclrck,
    aud_dacdat,
    aud_bclk,
    aud_xck
);
    parameter                           REF_CLK                   = 18432000;	//	18.432	MHz
    parameter                           SAMPLE_RATE               = 48000 ;		//	48		KHz
//	parameter	DATA_WIDTH		=	16;			//	16		Bits
    parameter                           CHANNEL_NUM               = 2     ;			//	Dual Channel
	
    parameter                           DATA_WIDTH                = 32    ;        //42:32; 46:40; 4A:48 4E:64 
	
    input                               clk                        ;
    input                               clk_18_3                   ;
    input                               rst_n                      ;
    output                              iis_scl                    ;
    input                               iis_i                      ;
    output                              iis_o                      ;
    output                              iis_oe                     ;
    output                              iis_done                   ;// iis 配置完成标志
	
    input                               aud_adcdat                 ;
    input                               aud_adclrck                ;
    input                               aud_daclrck                ;
    output                              aud_dacdat                 ;
    input                               aud_bclk                   ;
    output                              aud_xck                    ;
	
    assign                              aud_xck                   = clk_18_3;
   assign                              aud_dacdat                = aud_adcdat;
	
	
    i2s_init_dev u7(
    .Clk                                (clk                       ),
    .Rst_n                              (rst_n                     ),
    .Init_Done                          (iis_done                  ),
    .iis_scl                            (iis_scl                   ),
    .iis_i                              (iis_i                     ),
    .iis_o                              (iis_o                     ),
    .iis_oe                             (iis_oe                    ) 
    );

	
    // reg                                 adcfifo_read               ;
    // wire               [DATA_WIDTH - 1:0]adcfifo_readdata          ;
    // wire                                adcfifo_empty              ;
    // wire                                fifo_clear                 ;
	
    // reg                                 dacfifo_write              ;

	
    // reg                [DATA_WIDTH - 1:0]dacfifo_writedata         ;
    // wire                                dacfifo_full               ;
	

    // always @ (posedge clk or negedge rst_n)
    // begin
    //     if (~rst_n)
    //     begin
    //         adcfifo_read <= 1'b0;
    //     end
    //     else if (~adcfifo_empty)
    //     begin
    //         adcfifo_read <= 1'b1;
    //     end
    //     else
    //     begin
    //         adcfifo_read <= 1'b0;
    //     end
    // end

    // always @ (posedge clk or negedge rst_n)
    // begin
    //     if(~rst_n)
    //         dacfifo_write <= 1'd0;
    //     else if(~dacfifo_full && (~adcfifo_empty)) begin
    //         dacfifo_write <= 1'd1;
    //         dacfifo_writedata <= adcfifo_readdata;
    //     end
    //     else begin
    //         dacfifo_write <= 1'd0;
    //     end
    // end

    // i2s_rx
    // #(
    // .DATA_WIDTH                         (DATA_WIDTH                ) 
    // )i2s_rx
    // (
    // .reset_n                            (rst_n                     ),
    // .bclk                               (aud_bclk                  ),
    // .adclrc                             (aud_adclrck               ),
    // .adcdat                             (aud_adcdat                ),
    // .adcfifo_rdclk                      (clk                       ),
    // .adcfifo_read                       (adcfifo_read              ),
    // .adcfifo_empty                      (adcfifo_empty             ),
    // .adcfifo_readdata                   (adcfifo_readdata          ) 
    // );
	
    // i2s_tx
    // #(
    // .DATA_WIDTH                         (DATA_WIDTH                ) 
    // )i2s_tx
    // (
    // .reset_n                            (rst_n                     ),
    // .dacfifo_wrclk                      (clk                       ),
    // .dacfifo_wren                       (dacfifo_write             ),
    // .dacfifo_wrdata                     (dacfifo_writedata         ),
    // .dacfifo_full                       (dacfifo_full              ),
    // .bclk                               (aud_bclk                  ),
    // .daclrc                             (aud_adclrck               ),
    // .dacdat                             (aud_dacdat                ) 
    // );
	
endmodule
