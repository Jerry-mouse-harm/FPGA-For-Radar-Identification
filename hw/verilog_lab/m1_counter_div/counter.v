// 手撕练习：计数器（模 MOD）—— 自己补全实现，别看参考。
//
// 行为约定：
//   1) rst_n 低有效异步复位：cnt=0, done=0
//   2) en=1 时每个时钟沿 cnt 加 1
//   3) cnt 到 MOD-1 后、en=1 的下一拍回 0，同时 done 拉高 1 拍
//      （即：复位后第 MOD 个使能沿，done 输出高脉冲）
//   4) en=0 时 cnt 保持、done=0
//   5) WIDTH 需 >= log2(MOD)+1（本判分台 MOD=10, WIDTH=4）
//
// 记忆套路：1)一个 always @(posedge clk or negedge rst_n) 就够，
//           先判断复位，再判断 en，里面判断"到没到终点"。
//          2)在时序逻辑中所有都要用 “ <= ”作为赋值语句
module counter #(
  parameter WIDTH = 4,
  parameter MOD   = 10
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire             en,
  output reg  [WIDTH-1:0] cnt,
  output reg              done
);
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt <= 0;
      done <= 0;
    end
    else begin
      if (!en) begin
        done <= 0;
      end
      else if (cnt == MOD - 1) begin
        cnt <= 1'b0;
        done <= 1'b1;
      end
      else begin
        cnt <= cnt + 1'b1;
        done <= 1'b0;
      end
    end
  end

endmodule
