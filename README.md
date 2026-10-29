# INT8 NPU (8x8 systolic array): double-buffered core, descriptor DMA, ARM/Linux driver

| Layer | Files | What it is |
|---|---|---|
| Compute | `rtl/pe.v`, `rtl/systolic_array.v`, `rtl/npu_core.v` | 8x8 INT8 MAC array; **double-buffered**: two input banks plus an output buffer, so load, compute and output of consecutive tiles overlap. Per-tile bias/shift/ReLU travel with the tile. |
| Stream/APB wrapper | `rtl/npu_apb.v`, `rtl/npu_top.v`, `rtl/npu_bist.v`, `rtl/de10_npu_top.v` | AXI4-Stream + APB version with an on-board LED self-test (KEY[1]). |
| **SoC** | `rtl/npu_csr.v`, `rtl/npu_dma.v`, `rtl/npu_fifo.v`, `rtl/npu_soc_top.v` | Avalon-MM CSR slave + **descriptor-driven DMA master** that fetches descriptors and operands from DDR and writes results back. |
| Software | `sw/npu.h`, `sw/npu_demo.c`, `sw/gen_vectors.c` | ARM/Linux userspace driver and benchmark (`/dev/mem`), plus the generator that cross-checks the C data layout against the RTL. |
| Integration | `fpga/de10_soc/` | Platform Designer component + step-by-step guide for attaching it to the HPS. **Untested in the tool.** |
| Board demo | `fpga/de10_standard/de10_npu.*` | Quartus project for the standalone LED self-test. |

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

## Limitations / next steps

- Not yet built in Quartus or run on hardware; Platform Designer component is unverified in the tool.
- DMA uses single-beat transfers (no bursts); adding burst reads would remove the main throughput limit.
- Bias/shift/ReLU are per tile, but there is no per-channel scale/zero-point.
- The register-based buffers are large for an FPGA; mapping them to M10K memory blocks would save logic.

---

# Standalone AXI4-Stream/APB core (original interface documentation)

## Interfaces

**AXI4-Stream, N=8 bytes per beat.** Input packet = 2K beats: K beats of A columns (byte r = A[r][k]) then K beats
of W rows (byte c = W[k][c]), `tlast` on the final beat. Output packet = 8 beats, one output row each, `tlast` on the last.
Full backpressure is honored on both channels.

**APB3 register map** (zero wait states)

| Addr | Name | Description |
|---|---|---|
| 0x00 | CTRL | bit0 ReLU enable |
| 0x04 | SHIFT | requantization right shift (0..31), round-half-up |
| 0x08 | KLEN | K for next tile (1..32), reset value 8 |
| 0x0C | STATUS | bit0 busy (RO), bit1 done (sticky, W1C), bit2 error (sticky, W1C) |
| 0x10 + 4c | BIAS[c] | signed int32 bias for output column c (c = 0..7) |
| 0x40 | PERF | cycles of the last tile (last input beat to last output beat) |

Errors flagged: packet shorter/longer than 2K beats, K = 0 or K > 32 (packet swallowed). The core recovers and accepts the next packet.

## Standalone LED self-test (no ARM needed)

    cd fpga/de10_standard
    quartus_sh --flow compile de10_npu            # -> output_files/de10_npu.sof
    quartus_pgm -m jtag -o "p;output_files/de10_npu.sof@2"    # or the Quartus Programmer GUI

KEY[0] = reset, press KEY[1] to run a built-in tile through the NPU (APB + AXI4-Stream).
LEDR[0] running, LEDR[9] PASS, LEDR[8] FAIL.
