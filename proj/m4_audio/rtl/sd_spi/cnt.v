//dir:0Ϊ�ӷ���������1Ϊ����������
//en:Ϊ1���enʹ�ܶ�
//limit:Ϊ1�򵽴�����ֵ�󲻹�������ʼֵ��limit�ͼ�����done��Զ����Ϊ�ߣ������empty��full�ź�
//var:Ϊ1������ֵΪ�ǹ̶����ǿ�����
//dual:Ϊ1��ü�����Ϊ˫�������,��ʱdir����������Ч��dual�ͼ�������/���������ʹdone�ź���1
//max_value:����ֵ�����varΪ1�������ֵΪ������������ֵ
//max_value:����ֵ�����varΪ0�������ֵΪÿ���������ֵ����dirΪ0��������ֵ����dirΪ1��

//�˿ڹ���
//cnt_value:��������ǰ��ֵ
//done:�������Ƿ���/����
//empty:cnt_value�Ƿ�Ϊ0
//full:cnt_value�Ƿ�Ϊmax_value(varΪ0)��cnt_value�Ƿ�Ϊvar_value(varΪ1)
//cnt_en:�������enΪ1�����ɸö˿�ʹ�ܼ�����
//inc,dec:���Ϊ˫���������cnt_en��ʧЧ����ʱincΪ�ӷ�ʹ�ܣ�decΪ����ʹ��
//clk:ʱ���ź�
//rst:��λ�ź�
//����varΪsystem_verilogԭ���ԣ���ʹ��system_verilogʵ������ģ��ʱ
//������var_option��������varʹ��

//ע����������ʱ�����var������һ�μ�����������λ����load������ֵΪ1ʱ���cnt_valueΪ��varֵ
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