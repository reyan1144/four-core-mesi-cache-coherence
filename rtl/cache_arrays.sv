module cache_arrays (
  input  logic                  clk,
  input  logic                  rst,

  input  mesi_pkg::index_t       rd_index,
  output mesi_pkg::tag_t         rd_tag,
  output mesi_pkg::line_t        rd_data,
  output mesi_pkg::mesi_state_t  rd_state,

  input  mesi_pkg::index_t       snoop_index,
  output mesi_pkg::tag_t         snoop_tag,
  output mesi_pkg::line_t        snoop_data,
  output mesi_pkg::mesi_state_t  snoop_state,

  input  mesi_pkg::index_t       wr_index,

  input  logic                  tag_we,
  input  mesi_pkg::tag_t         wr_tag,

  input  logic                  data_we,
  input  mesi_pkg::line_t        wr_data,

  input  logic                  state_we,
  input  mesi_pkg::mesi_state_t  wr_state
);

  import mesi_pkg::*;

  tag_t        tag_array   [0:NUM_LINES-1];
  line_t       data_array  [0:NUM_LINES-1];
  mesi_state_t state_array [0:NUM_LINES-1];

  // Combinational read port for local requests.
  assign rd_tag   = tag_array[rd_index];
  assign rd_data  = data_array[rd_index];
  assign rd_state = state_array[rd_index];

  // Combinational read port for snoop requests.
  assign snoop_tag   = tag_array[snoop_index];
  assign snoop_data  = data_array[snoop_index];
  assign snoop_state = state_array[snoop_index];

  // A single write port, shared by the future controllers.
  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < NUM_LINES; i++) begin
        state_array[i] <= MESI_I;
      end
    end else begin

      if (tag_we) begin
        tag_array[wr_index] <= wr_tag;
      end

      if (data_we) begin
        data_array[wr_index] <= wr_data;
      end

      if (state_we) begin
        state_array[wr_index] <= wr_state;
      end

    end
  end

endmodule