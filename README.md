# Precision Core (Block-Adaptive Normalization) — FPGA QPU Project

This repository contains the **precision core** used in a block-floating-point (BFP) style quantum state engine. The core implements a **single-pass external memory model** by buffering one block on-chip, computing a block exponent update, then streaming normalized mantissas back out.

## What the Precision Core Does

At a high level, the precision core processes the quantum state in **blocks of amplitudes**:

1. **ACCUMULATE (ACCUM)**: Accept `BLOCK_SIZE` complex samples at full internal precision (`WORK_WIDTH`), store them into an on-chip block buffer (BRAM), and compute a conservative block maximum magnitude.
2. **SHIFT**: Compute the shift amount required to make values fit into the stored mantissa width, and update the block exponent.
3. **NORMALIZE (NORM)**: Read back the stored block from BRAM and **normalize + round** each complex sample down to `MANT_WIDTH` mantissas, producing a streaming output.
4. **DRAIN**: Safely drain any remaining output under backpressure before returning to idle.

The design is built to support **streaming throughput** with a **backpressure-safe output register**, making it suitable for connection to AXI/HBM writers.

## Key Parameters

All design-wide parameters and typedefs live in `qpu_pkg.sv`:

- `BLOCK_SIZE = 256` amplitudes per block
- `WORK_WIDTH = 32` internal signed datapath width (per real/imag)
- `MANT_WIDTH = 24` stored signed mantissa width (per real/imag)
- `EXP_WIDTH  = 8` block exponent width
- `GUARD_BITS = 1` additional headroom bits used in normalization
- `COMPLEX_WIDTH = 2*WORK_WIDTH` packed complex sample width

Complex sample types:
- `complex_work_t` = `{work_t real_num, work_t imaginary}`
- `complex_mant_t` = `{mant_t real_num, mant_t imaginary}`

## Files (Precision Core)

### `block_precision_core.sv`
Top-level precision engine implementing the block-level flow:
- Instantiates the block buffer, max tracker, LZC, and normalize/round units.
- Implements an FSM with states:
  - `S_IDLE`, `S_ACCUM`, `S_SHIFT`, `S_NORM`, `S_DRAIN` [3]
- Uses a backpressure-safe output holding register (`out_reg` / `out_valid`) to ensure `data_out` remains stable while `valid_out=1` until `ready_out` completes a transfer [3].

### `block_buffer.sv`
Dual-port memory inferred as BRAM:
- Synchronous write on `we`
- Synchronous read on `re` with **registered output** (`rdata` updates on clock edge), i.e. 1-cycle read latency [1]

### `max_tracker.sv`
Tracks the per-block conservative magnitude proxy:
- Per-sample: `local_max = max(abs(real), abs(imag))`
- Uses a **saturating abs** to handle the two’s-complement corner case `abs(-2^(W-1))` safely [5]

### `leading_zero_counter.sv`
Counts leading zeros in the unsigned `block_max`:
- Used to compute the highest set bit position (MSB position) for scaling decisions [4]

### `normalize_round.sv`
Per-sample normalization primitive:
- Arithmetic right shift by `shift_amt`
- Round-to-nearest-even down to `MANT_WIDTH`
- Includes saturation for mantissa overflow due to rounding [6]

### `block_counter.sv`
Counts accepted input samples during ACCUM:
- Emits `block_done` pulse after `BLOCK_SIZE` accepted inputs [2]

## Interfaces (block_precision_core)

### Input Stream (ACCUM)
- `valid_in`: asserted by upstream producer (compute engine)
- `ready_in`: asserted by this core only during `S_ACCUM` [3]
- `data_in`: `complex_work_t` (real/imag are signed `WORK_WIDTH`) [7]

### Output Stream (NORM)
- `valid_out`: asserted when output register contains a valid normalized sample [3]
- `ready_out`: backpressure from downstream consumer (e.g., AXI/HBM writer)
- `data_out`: `complex_mant_t` (real/imag are signed `MANT_WIDTH`) [7]

### Exponent
- `exp_in`: incoming exponent for the current block (unsigned `EXP_WIDTH`) [7]
- `exp_out`: updated exponent after applying normalization shift (with saturation on overflow) [3]

## How Normalization Works

### Conservative block maximum
During ACCUM, the core computes:
block_max = max over i in block ( max(abs(real_i), abs(imag_i)) )

This proxy is cheaper than magnitude-squared and is standard for block floating-point; it provides a safe upper bound for scaling [5].

### Shift computation
After ACCUM, the core computes the highest set bit position from LZC:
msb_pos = (WORK_WIDTH-1) - lzc(block_max)

and chooses:

TARGET_MAG_MSB = (MANT_WIDTH - 2 - GUARD_BITS)
shift_amt = max(0, msb_pos - TARGET_MAG_MSB)

so the block fits into the mantissa range with `GUARD_BITS` headroom [3].

### Mantissa rounding
Each value is shifted (`>>> shift_amt`) and then rounded-to-nearest-even down to `MANT_WIDTH` [6].

## Backpressure & BRAM Read Pipeline

- The block buffer read port is synchronous; data appears **one cycle after** asserting `re` [1].
- The core issues BRAM reads only when it has space to latch a returned value into its output register.
- `valid_out` stays asserted until `ready_out` completes the handshake, guaranteeing stable output under backpressure [3].
- `S_DRAIN` ensures the core does not return to idle until any pending output is consumed [3].

## Current Scope / Intended Use

This precision core is meant to be integrated into a larger RTL datapath (e.g., complex MAC lanes + AXI/HBM streaming). It is designed to be demo-friendly:
- deterministic behavior
- safe under backpressure
- block-local scaling
- quantization via rounding