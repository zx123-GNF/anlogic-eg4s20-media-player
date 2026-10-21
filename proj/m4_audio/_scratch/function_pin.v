module function_pin(
	iic_sda,
	iic_scl,
	
	mode,
	
	iis_scl,
	iis_i,
	iis_o,
	iis_oe,
	
	pcf8563_scl,
	pcf8563_i,
	pcf8563_o,
	pcf8563_oe
);
	inout iic_sda;
	output iic_scl;
	
	input mode;		//0：配置音频，1：读取pcf8563
	
	input iis_scl;
	output iis_i;
	input iis_o;
	input iis_oe;
	
	input pcf8563_scl;
	output pcf8563_i;
	input pcf8563_o;
	input pcf8563_oe;
	
	//iic_scl
	assign iic_scl = !mode ? iis_scl : pcf8563_scl;
	
	//in
	assign pcf8563_i = mode ? iic_sda : 1'bz;
	assign iis_i = !mode ? iic_sda : 1'bz;
		
	//out
	assign iic_sda = (mode == 'd0) ? (iis_oe ? iis_o : 1'bz) :
					 (mode == 'd1) ? (pcf8563_oe ? pcf8563_o : 1'bz) :
					 1'bz;
	
	// assign iic_sda = (mode == 'd0) ? ((pcf8563_oe == 1'b1) ? pcf8563_o : 1'bz) :
						  // (mode == 'd1) ? iis_o :
						  // 1'bz;
	
endmodule