module four_core_top (
  input  logic clk,
  input  logic rst,

  input  logic [mesi_pkg::NUM_CORES-1:0] req_valid,
  output logic [mesi_pkg::NUM_CORES-1:0] req_ready,
  input  logic [mesi_pkg::NUM_CORES-1:0] req_write,

  input  logic
    [mesi_pkg::NUM_CORES-1:0]
    [mesi_pkg::ADDR_W-1:0] req_addr,

  input  logic
    [mesi_pkg::NUM_CORES-1:0]
    [mesi_pkg::WORD_W-1:0] req_wdata,

  output logic [mesi_pkg::NUM_CORES-1:0] rsp_valid,
  input  logic [mesi_pkg::NUM_CORES-1:0] rsp_ready,

  output logic
    [mesi_pkg::NUM_CORES-1:0]
    [mesi_pkg::WORD_W-1:0] rsp_rdata
);

  import mesi_pkg::*;

  logic [NUM_CORES-1:0] requests;
  logic [NUM_CORES-1:0] grants;

  wire [NUM_CORES-1:0][2:0] cache_cmd;
  wire [NUM_CORES-1:0][ADDR_W-1:0] cache_addr;
  wire [NUM_CORES-1:0][LINE_W-1:0] cache_wline;

  logic [NUM_CORES-1:0] cache_accept;
  logic [NUM_CORES-1:0] cache_completion_valid;
  logic [NUM_CORES-1:0] cache_completion_ready;

  logic owner_valid;
  logic selected_request_valid;
  logic owner_accept;
  logic release_bus;

  core_id_t owner_id;
  core_id_t requester_id;

  bus_cmd_t owner_cmd;
  addr_t owner_addr;
  line_t owner_wline;

  logic [NUM_CORES-1:0] snoop_valid;
  logic [NUM_CORES-1:0] snoop_done;
  logic [NUM_CORES-1:0] snoop_has_copy;

  bus_cmd_t snoop_cmd;
  addr_t snoop_addr;

  logic [NUM_CORES-1:0] dirty_valid;
  logic [NUM_CORES-1:0] dirty_ready;
  logic [NUM_CORES-1:0] dirty_done;
  wire [NUM_CORES-1:0][LINE_W-1:0] dirty_lines;

  logic data_req_valid;
  logic data_req_ready;
  bus_cmd_t data_cmd;
  addr_t data_addr;
  line_t data_wline;

  logic data_rsp_valid;
  logic data_rsp_ready;
  line_t data_rline;

  logic completion_valid;
  logic completion_ready;
  logic shared_seen;
  line_t completion_line;

  logic memory_write;

  // A grant reserves ownership; the payload must also be valid.
  assign selected_request_valid =
    owner_valid && requests[owner_id];

  assign owner_addr  = cache_addr[owner_id];
  assign owner_wline = cache_wline[owner_id];

  assign completion_ready =
    cache_completion_ready[requester_id];

  // Select the granted cache's command.
  always_comb begin
    case (cache_cmd[owner_id])
      BUS_RD:   owner_cmd = BUS_RD;
      BUS_RDX:  owner_cmd = BUS_RDX;
      BUS_UPGR: owner_cmd = BUS_UPGR;
      BUS_WB:   owner_cmd = BUS_WB;
      default:  owner_cmd = BUS_NONE;
    endcase
  end

  generate
    for (genvar g = 0; g < NUM_CORES; g++) begin : caches

      assign cache_accept[g] =
        owner_accept && (owner_id == core_id_t'(g));

      assign cache_completion_valid[g] =
        completion_valid && (requester_id == core_id_t'(g));

      l1_cache cache_inst (
        .clk                  (clk),
        .rst                  (rst),

        .req_valid            (req_valid[g]),
        .req_ready            (req_ready[g]),
        .req_write            (req_write[g]),
        .req_addr             (req_addr[g]),
        .req_wdata            (req_wdata[g]),

        .rsp_valid            (rsp_valid[g]),
        .rsp_ready            (rsp_ready[g]),
        .rsp_rdata            (rsp_rdata[g]),

        .bus_request          (requests[g]),
        .bus_cmd              (cache_cmd[g]),
        .bus_addr             (cache_addr[g]),
        .bus_wline            (cache_wline[g]),
        .bus_accept           (cache_accept[g]),

        .bus_completion_valid (cache_completion_valid[g]),
        .bus_completion_ready (cache_completion_ready[g]),
        .bus_completion_line  (completion_line),
        .bus_shared_seen      (shared_seen),

        .snoop_valid          (snoop_valid[g]),
        .snoop_cmd            (snoop_cmd),
        .snoop_addr           (snoop_addr),
        .snoop_done           (snoop_done[g]),
        .snoop_has_copy       (snoop_has_copy[g]),

        .dirty_valid          (dirty_valid[g]),
        .dirty_ready          (dirty_ready[g]),
        .dirty_line           (dirty_lines[g]),
        .dirty_done           (dirty_done[g])
      );

    end
  endgenerate

  bus_arbiter arbiter (
    .clk         (clk),
    .rst         (rst),
    .requests    (requests),
    .release_bus (release_bus),
    .grants      (grants),
    .owner_valid (owner_valid),
    .owner_id    (owner_id)
  );

  coherence_bus_ctrl bus_controller (
    .clk              (clk),
    .rst              (rst),

    .owner_valid      (selected_request_valid),
    .owner_id         (owner_id),
    .owner_cmd        (owner_cmd),
    .owner_addr       (owner_addr),
    .owner_wline      (owner_wline),
    .owner_accept     (owner_accept),

    .snoop_valid      (snoop_valid),
    .snoop_cmd        (snoop_cmd),
    .snoop_addr       (snoop_addr),
    .requester_id     (requester_id),
    .snoop_done       (snoop_done),
    .snoop_has_copy   (snoop_has_copy),

    .dirty_valid      (dirty_valid),
    .dirty_ready      (dirty_ready),
    .dirty_done       (dirty_done),
    .dirty_lines      (dirty_lines),

    .data_req_valid   (data_req_valid),
    .data_req_ready   (data_req_ready),
    .data_cmd         (data_cmd),
    .data_addr        (data_addr),
    .data_wline       (data_wline),

    .data_rsp_valid   (data_rsp_valid),
    .data_rsp_ready   (data_rsp_ready),
    .data_rline       (data_rline),

    .completion_valid (completion_valid),
    .completion_ready (completion_ready),
    .completion_line  (completion_line),
    .shared_seen      (shared_seen),
    .release_bus      (release_bus)
  );

  // BusRd/BusRdX fetch data; BusUpgr never reaches this endpoint.
  assign memory_write = (data_cmd == BUS_WB);

  main_memory memory (
    .clk       (clk),
    .rst       (rst),

    .req_valid (data_req_valid),
    .req_ready (data_req_ready),
    .req_write (memory_write),
    .req_addr  (data_addr),
    .req_wline (data_wline),

    .rsp_valid (data_rsp_valid),
    .rsp_ready (data_rsp_ready),
    .rsp_rline (data_rline)
  );

endmodule