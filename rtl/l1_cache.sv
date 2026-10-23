module l1_cache (
  input  logic                          clk,
  input  logic                          rst,

  input  logic                          req_valid,
  output logic                          req_ready,
  input  logic                          req_write,
  input  mesi_pkg::addr_t                req_addr,
  input  mesi_pkg::word_t                req_wdata,

  output logic                          rsp_valid,
  input  logic                          rsp_ready,
  output mesi_pkg::word_t                rsp_rdata,

  output logic                          bus_request,
  output mesi_pkg::bus_cmd_t             bus_cmd,
  output mesi_pkg::addr_t                bus_addr,
  output mesi_pkg::line_t                bus_wline,
  input  logic                          bus_accept,

  input  logic                          bus_completion_valid,
  output logic                          bus_completion_ready,
  input  mesi_pkg::line_t                bus_completion_line,
  input  logic                          bus_shared_seen,

  input  logic                          snoop_valid,
  input  mesi_pkg::bus_cmd_t             snoop_cmd,
  input  mesi_pkg::addr_t                snoop_addr,
  output logic                          snoop_done,
  output logic                          snoop_has_copy,

  output logic                          dirty_valid,
  input  logic                          dirty_ready,
  output mesi_pkg::line_t                dirty_line,
  input  logic                          dirty_done
);

  import mesi_pkg::*;

  logic local_req_ready;

  index_t local_rd_index;
  tag_t local_rd_tag;
  line_t local_rd_data;
  mesi_state_t local_rd_state;

  index_t local_wr_index;
  logic local_tag_we;
  tag_t local_wr_tag;
  logic local_data_we;
  line_t local_wr_data;
  logic local_state_we;
  mesi_state_t local_wr_state;

  logic local_mem_req_valid;
  logic local_mem_req_write;
  logic local_mem_rsp_ready;

  index_t snoop_array_index;
  tag_t snoop_array_tag;
  line_t snoop_array_data;
  mesi_state_t snoop_array_state;

  logic snoop_update_valid;
  logic snoop_update_ready;
  index_t snoop_update_index;
  mesi_state_t snoop_update_state;

  index_t array_wr_index;
  logic array_tag_we;
  tag_t array_wr_tag;
  logic array_data_we;
  line_t array_wr_data;
  logic array_state_we;
  mesi_state_t array_wr_state;

  logic snoop_active;
  logic allow_fill;

  assign req_ready = !rst && local_req_ready;
  assign bus_request = local_mem_req_valid;

  // Block local lookup/updates until snoop processing finishes.
  assign allow_fill = !snoop_active &&
                      !snoop_valid &&
                      !snoop_update_valid;

  assign bus_completion_ready = !rst &&
                                allow_fill &&
                                local_mem_rsp_ready;

  assign snoop_update_ready = !rst;

  // Remains asserted during dirty capture, flush, and state update.
  always_ff @(posedge clk) begin
    if (rst) begin
      snoop_active <= 1'b0;
    end else begin
      if (snoop_valid) begin
        snoop_active <= 1'b1;
      end else if (snoop_done) begin
        snoop_active <= 1'b0;
      end
    end
  end

  cache_controller local_controller (
    .clk                (clk),
    .rst                (rst),

    .req_valid          (req_valid),
    .req_ready          (local_req_ready),
    .req_write          (req_write),
    .req_addr           (req_addr),
    .req_wdata          (req_wdata),

    .rsp_valid          (rsp_valid),
    .rsp_ready          (rsp_ready),
    .rsp_rdata          (rsp_rdata),

    .rd_index           (local_rd_index),
    .rd_tag             (local_rd_tag),
    .rd_data            (local_rd_data),
    .rd_state           (local_rd_state),
    .array_access_ready (allow_fill),

    .wr_index           (local_wr_index),
    .tag_we             (local_tag_we),
    .wr_tag             (local_wr_tag),
    .data_we            (local_data_we),
    .wr_data            (local_wr_data),
    .state_we           (local_state_we),
    .wr_state           (local_wr_state),

    .mem_req_valid      (local_mem_req_valid),
    .mem_req_ready      (bus_accept),
    .mem_req_cmd        (bus_cmd),
    .mem_req_write      (local_mem_req_write),
    .mem_req_addr       (bus_addr),
    .mem_req_wline      (bus_wline),

    .mem_rsp_valid      (bus_completion_valid && allow_fill),
    .mem_rsp_ready      (local_mem_rsp_ready),
    .mem_rsp_rline      (bus_completion_line),

    .fill_shared        (bus_shared_seen)
  );

  snoop_controller snooper (
    .clk            (clk),
    .rst            (rst),

    .snoop_valid    (snoop_valid),
    .snoop_cmd      (snoop_cmd),
    .snoop_addr     (snoop_addr),
    .snoop_done     (snoop_done),
    .snoop_has_copy (snoop_has_copy),

    .array_index    (snoop_array_index),
    .array_tag      (snoop_array_tag),
    .array_data     (snoop_array_data),
    .array_state    (snoop_array_state),

    .update_valid   (snoop_update_valid),
    .update_ready   (snoop_update_ready),
    .update_index   (snoop_update_index),
    .update_state   (snoop_update_state),

    .dirty_valid    (dirty_valid),
    .dirty_ready    (dirty_ready),
    .dirty_line     (dirty_line),
    .dirty_done     (dirty_done)
  );

  // Snoop state updates have priority over local writes.
  always_comb begin
    array_wr_index = local_wr_index;
    array_tag_we   = local_tag_we;
    array_wr_tag   = local_wr_tag;
    array_data_we  = local_data_we;
    array_wr_data  = local_wr_data;
    array_state_we = local_state_we;
    array_wr_state = local_wr_state;

    if (snoop_update_valid) begin
      array_wr_index = snoop_update_index;

      array_tag_we  = 1'b0;
      array_data_we = 1'b0;

      array_state_we = snoop_update_valid &&
                       snoop_update_ready;

      array_wr_state = snoop_update_state;
    end
  end

  cache_arrays arrays (
    .clk         (clk),
    .rst         (rst),

    .rd_index    (local_rd_index),
    .rd_tag      (local_rd_tag),
    .rd_data     (local_rd_data),
    .rd_state    (local_rd_state),

    .snoop_index (snoop_array_index),
    .snoop_tag   (snoop_array_tag),
    .snoop_data  (snoop_array_data),
    .snoop_state (snoop_array_state),

    .wr_index    (array_wr_index),
    .tag_we      (array_tag_we),
    .wr_tag      (array_wr_tag),
    .data_we     (array_data_we),
    .wr_data     (array_wr_data),
    .state_we    (array_state_we),
    .wr_state    (array_wr_state)
  );

  always @(posedge clk) begin
    if (!rst) begin
      if (snoop_valid && snoop_active) begin
        $fatal(1, "New snoop arrived before previous snoop completed");
      end
    end
  end

endmodule