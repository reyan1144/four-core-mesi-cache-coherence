package mesi_pkg;

  // System configuration
  localparam int unsigned NUM_CORES  = 4;
  localparam int unsigned ADDR_W     = 32;
  localparam int unsigned WORD_W     = 32;
  localparam int unsigned LINE_BYTES = 16;
  localparam int unsigned NUM_LINES  = 16;
  localparam int unsigned MEM_BYTES  = 4096;

  // Derived widths
  localparam int unsigned WORD_BYTES     = WORD_W / 8;
  localparam int unsigned WORDS_PER_LINE = LINE_BYTES / WORD_BYTES;
  localparam int unsigned LINE_W         = LINE_BYTES * 8;

  localparam int unsigned OFFSET_W   = $clog2(LINE_BYTES);
  localparam int unsigned INDEX_W    = $clog2(NUM_LINES);
  localparam int unsigned TAG_W      = ADDR_W - INDEX_W - OFFSET_W;
  localparam int unsigned WORD_SEL_W = $clog2(WORDS_PER_LINE);
  localparam int unsigned CORE_ID_W  = $clog2(NUM_CORES);

  // Shared data types
  typedef logic [ADDR_W-1:0]     addr_t;
  typedef logic [WORD_W-1:0]     word_t;
  typedef logic [LINE_W-1:0]     line_t;
  typedef logic [TAG_W-1:0]      tag_t;
  typedef logic [INDEX_W-1:0]    index_t;
  typedef logic [OFFSET_W-1:0]   offset_t;
  typedef logic [WORD_SEL_W-1:0] word_sel_t;
  typedef logic [CORE_ID_W-1:0]  core_id_t;

  // Stable MESI states; controller wait states will be defined separately.
  typedef enum logic [1:0] {
    MESI_I = 2'b00,
    MESI_S = 2'b01,
    MESI_E = 2'b10,
    MESI_M = 2'b11
  } mesi_state_t;

  // Bus commands
  typedef enum logic [2:0] {
    BUS_NONE = 3'd0,
    BUS_RD   = 3'd1,
    BUS_RDX  = 3'd2,
    BUS_UPGR = 3'd3,
    BUS_WB   = 3'd4
  } bus_cmd_t;

  // Baseline address layout: tag [31:8], index [7:4], offset [3:0].
  function automatic tag_t get_tag(input addr_t addr);
    return addr[ADDR_W-1 : OFFSET_W + INDEX_W];
  endfunction

  function automatic index_t get_index(input addr_t addr);
    return addr[OFFSET_W +: INDEX_W];
  endfunction

  function automatic offset_t get_offset(input addr_t addr);
    return addr[OFFSET_W-1:0];
  endfunction

  function automatic word_sel_t get_word_sel(input addr_t addr);
    return addr[$clog2(WORD_BYTES) +: WORD_SEL_W];
  endfunction

  // Clear the offset bits to obtain the line's starting address.
  function automatic addr_t line_base(input addr_t addr);
    return {
      addr[ADDR_W-1:OFFSET_W],
      {OFFSET_W{1'b0}}
    };
  endfunction

  // Reconstruct the cached victim's address for writeback.
  function automatic addr_t victim_base(
    input tag_t   tag,
    input index_t index
  );
    return {tag, index, {OFFSET_W{1'b0}}};
  endfunction

endpackage : mesi_pkg