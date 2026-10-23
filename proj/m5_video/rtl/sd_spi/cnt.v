//dir:0为加法计数器，1为减法计数器
//en:为1则带en使能端
//limit:为1则到达限制值后不归零至初始值，limit型计数器done永远不会为高，请改用empty和full信号
//var:为1则上限值为非固定而是可配置
//dual:为1则该计数器为双向计数器,此时dir参数不再生效，dual型计数器上/下溢出都会使done信号置1
//max_value:上限值，如果var为1，则该数值为最大可设置上限值
//max_value:上限值，如果var为0，则该数值为每次溢出上限值（当dir为0）或重载值（当dir为1）

//端口功能
//cnt_value:计数器当前数值
//done:计数器是否上/下溢
//empty:cnt_value是否为0
//full:cnt_value是否为max_value(var为0)，cnt_value是否为var_value(var为1)
//cnt_en:如果参数en为1，则由该端口使能计数器
//inc,dec:如果为双向计数器，cnt_en端失效，此时inc为加法使能，dec为减法使能
//clk:时钟信号
//rst:复位信号
//由于var为system_verilog原语言，如使用system_verilog实例化本模块时
//可以用var_option参数代替var使用

//注：减法计数时，若打开var，则在一次计数结束，复位或者load参数赋值为1时填充cnt_value为新var值
module cnt #(parameter
    dir = 0,
    en = 0,
    limit = 0,
    var_option = 0,
    var = var_option,
    dual = 0,
    max_value = 10,
    width = max_value > 0 ? $clog2(max_value) : 1
    )
    (
    output reg         [width-1: 0]     cnt_value                  ,
    output reg                          done                       ,
    output                              empty                      ,
    output reg                          full                       ,
    input              [width-1: 0]     var_value                  ,
    input                               load                       ,
    input                               cnt_en                     ,
    input                               inc                        ,
    input                               dec                        ,
    input                               clk                        ,
    input                               rst                         
    );
    
    assign                              empty                     = cnt_value == 0;
    
    always@(*)
    begin
        if(var)
            full <= cnt_value == var_value - 1;
        else
            full <= cnt_value == max_value - 1;
    end
    
    always@(*)
    begin
        if(var) begin
            if(limit)
                done <= 0;
            else if(dual) begin
                case({inc,dec})
                    2'b00: done <= 0;
                    2'b01: done <= cnt_value == 0;
                    2'b10: done <= cnt_value >= var_value - 1;
                    2'b11: done <= 0;
                endcase
            end
            else if(en) begin
                if(cnt_en) begin
                    if(dir) begin
                        done <= cnt_value == 0;
                    end
                    else begin
                        done <= cnt_value >= var_value - 1;
                    end
                end
                else
                    done <= 0;
            end
            else begin
                if(dir) begin
                    done <= cnt_value == 0;
                end
                else begin
                    done <= cnt_value >= var_value - 1;
                end
            end
        end
        else begin
            if(limit)
                done <= 0;
            else if(dual) begin
                case({inc,dec})
                    2'b00: done <= 0;
                    2'b01: done <= cnt_value == 0;
                    2'b10: done <= cnt_value >= max_value - 1;
                    2'b11: done <= 0;
                endcase
            end
            else if(en) begin
                if(cnt_en) begin
                    if(dir) begin
                        done <= cnt_value == 0;
                    end
                    else begin
                        done <= cnt_value >= max_value - 1;
                    end
                end
                else
                    done <= 0;
            end
            else begin
                if(dir) begin
                    done <= cnt_value == 0;
                end
                else begin
                    done <= cnt_value >= max_value - 1;
                end
            end
        end
    end
    
    always@(posedge clk or posedge rst)
    begin
        if(var) begin
            if(dual) begin
                if(limit) begin
                    if(rst) begin
                        cnt_value <= 0;
                    end
                    else if(load)
                        cnt_value <= var_value - 1;
                    else begin
                        case({inc,dec})
                            2'b00: cnt_value <= cnt_value;
                            2'b01: begin
                                if(cnt_value == 0)
                                    cnt_value <= cnt_value;
                                else
                                    cnt_value <= cnt_value - 1;
                            end
                            2'b10: begin
                                if(cnt_value == var_value - 1)
                                    cnt_value <= cnt_value;
                                else
                                    cnt_value <= cnt_value + 1;
                            end
                            2'b11: cnt_value <= cnt_value;
                        endcase
                    end
                end
                else begin
                    if(rst) begin
                        cnt_value <= 0;
                    end
                    else if(load && dir)
                        cnt_value <= var_value - 1;
                    else begin
                        case({inc,dec})
                            2'b00: cnt_value <= cnt_value;
                            2'b01: begin
                                if(cnt_value == 0)
                                    cnt_value <= var_value - 1;
                                else
                                    cnt_value <= cnt_value - 1;
                            end
                            2'b10: begin
                                if(cnt_value == var_value - 1)
                                    cnt_value <= 0;
                                else
                                    cnt_value <= cnt_value + 1;
                            end
                            2'b11: cnt_value <= cnt_value;
                        endcase
                    end
                end
            end
            else if(en) begin
                if(rst) begin
                    if(dir)
                        cnt_value <= var_value - 1;
                    else
                        cnt_value <= 0;
                end
                else if(load && dir)
                    cnt_value <= var_value - 1;
                else if(cnt_en) begin
                    if(limit) begin
                        if(dir) begin
                            if(cnt_value == 0)
                                cnt_value <= cnt_value;
                            else
                                cnt_value <= cnt_value - 1;
                        end
                        else begin
                            if(cnt_value == var_value - 1)
                                cnt_value <= cnt_value;
                            else
                                cnt_value <= cnt_value + 1;
                        end
                    end
                    else begin
                        if(dir) begin
                            if(cnt_value == 0)
                                cnt_value <= var_value - 1;
                            else
                                cnt_value <= cnt_value - 1;
                        end
                        else begin
                            if(cnt_value == var_value - 1)
                                cnt_value <= 0;
                            else
                                cnt_value <= cnt_value + 1;
                        end
                    end
                end
            end
            else begin
                if(rst) begin
                    if(dir)
                        cnt_value <= var_value - 1;
                    else
                        cnt_value <= 0;
                end
                else if(load && dir)
                    cnt_value <= var_value - 1;
                else begin
                    if(limit) begin
                        if(dir) begin
                            if(cnt_value == 0)
                                cnt_value <= cnt_value;
                            else
                                cnt_value <= cnt_value - 1;
                        end
                        else begin
                            if(cnt_value == var_value - 1)
                                cnt_value <= cnt_value;
                            else
                                cnt_value <= cnt_value + 1;
                        end
                    end
                    else begin
                        if(dir) begin
                            if(cnt_value == 0)
                                cnt_value <= var_value - 1;
                            else
                                cnt_value <= cnt_value - 1;
                        end
                        else begin
                            if(cnt_value == var_value - 1)
                                cnt_value <= 0;
                            else
                                cnt_value <= cnt_value + 1;
                        end
                    end
                end
            end
        end
        else begin
            if(dual) begin
                if(limit) begin
                    if(rst) begin
                        cnt_value <= 0;
                    end
                    else begin
                        case({inc,dec})
                            2'b00: cnt_value <= cnt_value;
                            2'b01: begin
                                if(cnt_value == 0)
                                    cnt_value <= cnt_value;
                                else
                                    cnt_value <= cnt_value - 1;
                            end
                            2'b10: begin
                                if(cnt_value == max_value - 1)
                                    cnt_value <= cnt_value;
                                else
                                    cnt_value <= cnt_value + 1;
                            end
                            2'b11: cnt_value <= cnt_value;
                        endcase
                    end
                end
                else begin
                    if(rst) begin
                        cnt_value <= 0;
                    end
                    else begin
                        case({inc,dec})
                            2'b00: cnt_value <= cnt_value;
                            2'b01: begin
                                if(cnt_value == 0)
                                    cnt_value <= max_value - 1;
                                else
                                    cnt_value <= cnt_value - 1;
                            end
                            2'b10: begin
                                if(cnt_value == max_value - 1)
                                    cnt_value <= 0;
                                else
                                    cnt_value <= cnt_value + 1;
                            end
                            2'b11: cnt_value <= cnt_value;
                        endcase
                    end
                end
            end
            else if(en) begin
                if(rst) begin
                    if(dir)
                        cnt_value <= max_value - 1;
                    else
                        cnt_value <= 0;
                end
                else if(cnt_en) begin
                    if(limit) begin
                        if(dir) begin
                            if(cnt_value == 0)
                                cnt_value <= cnt_value;
                            else
                                cnt_value <= cnt_value - 1;
                        end
                        else begin
                            if(cnt_value == max_value - 1)
                                cnt_value <= cnt_value;
                            else
                                cnt_value <= cnt_value + 1;
                        end
                    end
                    else begin
                        if(dir) begin
                            if(cnt_value == 0)
                                cnt_value <= max_value - 1;
                            else
                                cnt_value <= cnt_value - 1;
                        end
                        else begin
                            if(cnt_value == max_value - 1)
                                cnt_value <= 0;
                            else
                                cnt_value <= cnt_value + 1;
                        end
                    end
                end
            end
            else begin
                if(rst) begin
                    if(dir)
                        cnt_value <= max_value - 1;
                    else
                        cnt_value <= 0;
                end
                else begin
                    if(limit) begin
                        if(dir) begin
                            if(cnt_value == 0)
                                cnt_value <= cnt_value;
                            else
                                cnt_value <= cnt_value - 1;
                        end
                        else begin
                            if(cnt_value == max_value - 1)
                                cnt_value <= cnt_value;
                            else
                                cnt_value <= cnt_value + 1;
                        end
                    end
                    else begin
                        if(dir) begin
                            if(cnt_value == 0)
                                cnt_value <= max_value - 1;
                            else
                                cnt_value <= cnt_value - 1;
                        end
                        else begin
                            if(cnt_value == max_value - 1)
                                cnt_value <= 0;
                            else
                                cnt_value <= cnt_value + 1;
                        end
                    end
                end
            end
        end
    end
    
endmodule