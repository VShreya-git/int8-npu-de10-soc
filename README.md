# INT8 NPU (8x8 systolic array): double-buffered core, descriptor DMA, ARM/Linux driver

> **Status:** everything below is verified in simulation (`make test`). Nothing has been compiled in Quartus or
> run on a real DE10-Standard yet, so there are no hardware resource, Fmax or power numbers.

## What is in the box

| Layer | Files | What it is |
|---|---|---|
| Compute | `rtl/pe.v`, `rtl/systolic_array.v`, `rtl/npu_core.v` | 8x8 INT8 MAC array; **double-buffered**: two input banks plus an output buffer, so load, compute and output of consecutive tiles overlap. Per-tile bias/shift/ReLU travel with the tile. |
| Stream/APB wrapper | `rtl/npu_apb.v`, `rtl/npu_top.v`, `rtl/npu_bist.v`, `rtl/de10_npu_top.v` | AXI4-Stream + APB version with an on-board LED self-test (KEY[1]). |
| **SoC** | `rtl/npu_csr.v`, `rtl/npu_dma.v`, `rtl/npu_fifo.v`, `rtl/npu_soc_top.v` | Avalon-MM CSR slave + **descriptor-driven DMA master** that fetches descriptors and operands from DDR and writes results back. |
| Software | `sw/npu.h`, `sw/npu_demo.c`, `sw/gen_vectors.c` | ARM/Linux userspace driver and benchmark (`/dev/mem`), plus the generator that cross-checks the C data layout against the RTL. |
| Integration | `fpga/de10_soc/` | Platform Designer component + step-by-step guide for attaching it to the HPS. **Untested in the tool.** |
| Board demo | `fpga/de10_standard/de10_npu.*` | Quartus project for the standalone LED self-test. |

## Simulation evidence

All figures are generated from the actual simulation (`make plots`): waveforms come from the VCD dumps, the data
from the testbench outputs. A small VCD for GTKWave is in `docs/waves/`.

**1. Pipeline occupancy (from the waveform).** The single-buffered core does one stage at a time. The double-buffered core
loads tile n+1 while tile n computes and tile n-1 streams out: 322 cycles instead of 483 for four K=32 tiles.

![pipeline timeline](docs/01_pipeline_timeline.png)

**2. Signal-level waveform** of the double-buffered core (3 tiles, K=4). Both input banks fill (`full` = 01 -> 11 -> 10),
the array computes the first tile while the second is still loading, results are captured into the output buffer and streamed with `tlast`.

![waveform](docs/02_waveform.png)

**3. Throughput vs K.** Double buffering helps more as compute grows (1.04x at K=1, 1.76x at K=32) and approaches the
input-stream limit of 2K cycles per tile. At K=1 there is almost nothing to overlap.

![k sweep](docs/03_k_sweep.png)

**4. Bit-exact correctness.** A DDR image built by the C driver code goes through the DMA and the NPU RTL; all 4096 output
bytes of 64 random tiles (random K, shift, ReLU, bias) equal the C reference. The histogram shows saturation at both ends and ReLU zeros were exercised.

![correctness](docs/04_correctness.png)

**5. DMA run.** 64 tiles through the descriptor DMA: 76 cycles/tile with random K and a memory model that injects 25% wait states.
Reads (descriptors + operands) dominate the port traffic, which is why the DMA, not the array, limits throughput.

![dma activity](docs/05_dma_activity.png)

## Verification results (`make test`, Icarus Verilog)

- `tb_npu`: 319 checks (corner cases, 300 random tiles with random stalls, tiled layers, overlapped tiles with per-tile config, error recovery)
- `tb_soc`: full system against a randomized DDR model (random waitrequest, latency): random tiles of every K, slow memory, chained 16x32x16 layer, bad descriptor, recovery, zero-length run
- `tb_swvec`: DDR image built by the **C driver code** is processed by the RTL and matches the C reference, so the software layout equals the hardware layout (verified to fail when the byte order is deliberately broken)
- `tb_overlap`: double buffering benchmark, identical outputs from both cores:
  single-buffered baseline **120 cycles/tile**, double-buffered **68 cycles/tile (1.76x)** for K=32 at one stream beat per cycle
- `tb_board`: LED self-test on the board top
- Yosys synthesizes the core and the SoC top without errors or warnings

## Performance notes (simulation)

- Core: an 8x8 tile with K=32 needs 57 compute cycles; steady-state throughput is limited by the input stream (2K beats per tile).
- Through the DMA with an ideal memory: about 89 cycles/tile for K=32. The DMA has a single Avalon port and no bursts, so it moves
  one 64-bit beat per cycle shared between descriptor reads, operand reads and write-back. That is the bottleneck, not the array.

## SoC register map (`rtl/npu_csr.v`, 32-bit words)

| Word | Name | Description |
|---|---|---|
| 0 | CTRL | bit0 start (self-clearing), bit1 irq enable |
| 1 | DESC_BASE | physical address of the descriptor table |
| 2 | DESC_COUNT | number of descriptors |
| 3 | STATUS | bit0 busy, bit1 done (W1C), bit2 error (W1C) |
| 4 | TILES_DONE | tiles written back in this run |
| 5 | TILE_CYCLES | compute cycles of the latest tile |
| 6 | RUN_CYCLES | clocks from start to done of the last run |
| 7 | ID | 0x4E505532 |

Descriptor format and data layout: see `sw/npu.h`. An error interrupt is only raised after the engine has drained.

## Run

    make test                       # all simulations (needs iverilog and gcc)
    # on the board, after following fpga/de10_soc/README_SOC.md:
    cd sw && make npu_demo && sudo ./npu_demo

KEY[0] = reset, press KEY[1] to run a built-in tile through the NPU (APB + AXI4-Stream).
LEDR[0] running, LEDR[9] PASS, LEDR[8] FAIL.
