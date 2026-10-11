# verilog_lab Makefile —— 指向 conda env 里的 iverilog
CONDA  := /home/jierui/miniconda3/envs/verilog-sim
IVL    := $(CONDA)/bin/iverilog
VVP    := $(CONDA)/bin/vvp
GTKW   := $(CONDA)/bin/gtkwave

.PHONY: all m1 m2 m3 m4 m5 m6 clean m1_view

all: m1

# ============ M1 计数器 + 任意分频 ============
m1:
	cd m1_counter_div && $(IVL) -g2012 -o tb_counter.out tb_counter.v counter.v && $(VVP) tb_counter.out
	cd m1_counter_div && $(IVL) -g2012 -o tb_div.out    tb_div.v    div_N.v    && $(VVP) tb_div.out

m1_view:
	cd m1_counter_div && $(GTKW) tb_counter.vcd &
	cd m1_counter_div && $(GTKW) tb_div.vcd &

# ============ M2 边沿检测 + 按键消抖 ============
m2:
	cd m2_debounce && $(IVL) -g2012 -o tb_edge.out     tb_edge.v     edge_det.v   && $(VVP) tb_edge.out
	cd m2_debounce && $(IVL) -g2012 -o tb_debounce.out tb_debounce.v key_debounce.v && $(VVP) tb_debounce.out

# ============ M3 移位寄存器 + 并串/串并转换 ============
m3:
	cd m3_shift && $(IVL) -g2012 -o tb_shift.out tb_shift.v shift_reg.v && $(VVP) tb_shift.out
	cd m3_shift && $(IVL) -g2012 -o tb_p2s.out   tb_p2s.v   p2s.v       && $(VVP) tb_p2s.out
	cd m3_shift && $(IVL) -g2012 -o tb_s2p.out   tb_s2p.v   s2p.v       && $(VVP) tb_s2p.out
	cd m3_shift && $(IVL) -g2012 -o tb_loop.out  tb_loop.v  p2s.v s2p.v && $(VVP) tb_loop.out

# ============ M4 三段式状态机（序列检测 1011）============
m4:
	cd m4_fsm_seq && $(IVL) -g2012 -o tb_seq.out tb_seq.v seq_det.v && $(VVP) tb_seq.out

# ============ M5 UART 收发（8N1, 位长 = CLK_FREQ/BAUD）============
m5:
	cd m5_uart && $(IVL) -g2012 -o tb_uart_tx.out   tb_uart_tx.v   uart_tx.v           && $(VVP) tb_uart_tx.out
	cd m5_uart && $(IVL) -g2012 -o tb_uart_rx.out   tb_uart_rx.v   uart_rx.v           && $(VVP) tb_uart_rx.out
	cd m5_uart && $(IVL) -g2012 -o tb_uart_loop.out tb_uart_loop.v uart_tx.v uart_rx.v && $(VVP) tb_uart_loop.out

# ============ M6 脉冲编码前端（定点映射 + ΣΔ spread 编码）============
m6:
	cd m6_encoder && $(IVL) -g2012 -o tb_sample_to_n.out   tb_sample_to_n.v   sample_to_n.v                  && $(VVP) tb_sample_to_n.out
	cd m6_encoder && $(IVL) -g2012 -o tb_spike_encoder.out tb_spike_encoder.v spike_encoder.v                && $(VVP) tb_spike_encoder.out
	cd m6_encoder && $(IVL) -g2012 -o tb_m6_chain.out      tb_m6_chain.v      sample_to_n.v spike_encoder.v && $(VVP) tb_m6_chain.out

clean:
	find . -name '*.out' -delete
	find . -name '*.vcd' -delete
