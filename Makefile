BASE   = rtl/pe.v rtl/systolic_array.v rtl/npu_core.v
CORE   = $(BASE) rtl/npu_apb.v rtl/npu_top.v
BOARD  = $(CORE) rtl/npu_bist.v rtl/de10_npu_top.v
SOC    = $(BASE) rtl/npu_fifo.v rtl/npu_csr.v rtl/npu_dma.v rtl/npu_soc_top.v

.PHONY: test sim sim_board sim_soc sim_swvec sim_overlap plots wave clean

test: sim sim_board sim_soc sim_swvec sim_overlap

sim: sim/tb_npu.vvp
	vvp sim/tb_npu.vvp | grep -E "PASS|FAIL|INFO"

sim_board: sim/tb_board.vvp
	vvp sim/tb_board.vvp | grep -E "PASS|FAIL"

sim_soc: sim/tb_soc.vvp
	vvp sim/tb_soc.vvp | grep -E "PASS|FAIL|INFO"

sim_swvec: sim/tb_swvec.vvp sw/gen_vectors
	sw/gen_vectors 16 7 sim/sw_mem.hex sim/sw_exp.hex
	vvp sim/tb_swvec.vvp | grep -E "PASS|FAIL"

sim_overlap: sim/tb_overlap.vvp
	vvp sim/tb_overlap.vvp | grep -vE "finish|^$$"

sim/tb_npu.vvp: $(CORE) tb/tb_npu.v
	mkdir -p sim
	iverilog -g2012 -o $@ tb/tb_npu.v $(CORE)

sim/tb_board.vvp: $(BOARD) tb/tb_board.v
	mkdir -p sim
	iverilog -g2012 -o $@ tb/tb_board.v $(BOARD)

sim/tb_soc.vvp: $(SOC) tb/tb_soc.v
	mkdir -p sim
	iverilog -g2012 -o $@ tb/tb_soc.v $(SOC)

sim/tb_swvec.vvp: $(SOC) tb/tb_swvec.v
	mkdir -p sim
	iverilog -g2012 -o $@ tb/tb_swvec.v $(SOC)

sim/tb_overlap.vvp: $(BASE) tb/ref/npu_core_v1.v tb/tb_overlap.v
	mkdir -p sim
	iverilog -g2012 -o $@ tb/tb_overlap.v tb/ref/npu_core_v1.v $(BASE)

sw/gen_vectors: sw/gen_vectors.c sw/npu.h
	$(MAKE) -C sw gen_vectors

# Re-runs the simulations that dump waveforms/data and regenerates docs/*.png (needs python3 + matplotlib)
plots: sw/gen_vectors
	mkdir -p sim docs/waves
	iverilog -g2012 -Ptb_overlap.T=4 -Ptb_overlap.K=32 -o sim/ov_a.vvp tb/tb_overlap.v tb/ref/npu_core_v1.v $(BASE)
	vvp sim/ov_a.vvp +vcd=sim/timeline.vcd > /dev/null
	iverilog -g2012 -Ptb_overlap.T=3 -Ptb_overlap.K=4 -o sim/ov_b.vvp tb/tb_overlap.v tb/ref/npu_core_v1.v $(BASE)
	vvp sim/ov_b.vvp +vcd=sim/wave.vcd > /dev/null
	cp sim/wave.vcd docs/waves/core_double_buffer.vcd
	: > sim/sweep.txt
	for k in 1 2 4 8 16 32; do \
	  iverilog -g2012 -Ptb_overlap.T=16 -Ptb_overlap.K=$$k -o sim/ov_k.vvp tb/tb_overlap.v tb/ref/npu_core_v1.v $(BASE); \
	  echo "K=$$k $$(vvp sim/ov_k.vvp | grep -E 'single-buffered|double-buffered|PASS|FAIL' | tr '\n' ' ')" >> sim/sweep.txt; \
	done
	sw/gen_vectors 64 11 sim/sw_mem.hex sim/sw_exp.hex
	iverilog -g2012 -Ptb_swvec.NTILES=64 -o sim/swv.vvp tb/tb_swvec.v $(SOC)
	vvp sim/swv.vvp +vcd=sim/dma.vcd | grep -E "PASS|FAIL"
	python3 scripts/make_plots.py

wave: sim
	gtkwave sim/tb_npu.vcd

clean:
	rm -rf sim
	$(MAKE) -C sw clean
