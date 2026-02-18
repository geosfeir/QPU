package qpu_pkg;

    // Block Floating Point parameters
    parameter int BLOCK_SIZE      = 256;     // amplitudes per block
    parameter int MANT_WIDTH      = 24;      // stored mantissa width
    parameter int WORK_WIDTH      = 32;      // internal compute width
    parameter int EXP_WIDTH       = 8;       // block exponent width

    // Parallelism
    parameter int PARALLEL_LANES  = 16;      // DSP lanes (safe timing)

    // AXI / Memory
    parameter int AXI_DATA_WIDTH  = 512;     // U50 HBM port width
    parameter int AXI_ADDR_WIDTH  = 33;      // depends on memory map

    // Derived Parameters (DO NOT EDIT)

    parameter int COMPLEX_WIDTH       = 2 * WORK_WIDTH;
    parameter int STORED_COMPLEX_W    = 2 * MANT_WIDTH;

    parameter int BLOCK_ADDR_WIDTH    = $clog2(BLOCK_SIZE);

    // Guard bits used during normalization
    parameter int GUARD_BITS          = 1;

    // Rounding bits (for round-to-nearest-even)
    parameter int ROUND_BITS          = WORK_WIDTH - MANT_WIDTH;

    // Typedefs
    typedef logic signed [WORK_WIDTH-1:0]  work_t;
    typedef logic signed [MANT_WIDTH-1:0]  mant_t;
    typedef logic        [EXP_WIDTH-1:0]   exp_t;

    typedef struct packed {
        work_t real_num;
        work_t imaginary;
    } complex_work_t;

    typedef struct packed {
        mant_t real_num;
        mant_t imaginary;
    } complex_mant_t;

endpackage