module cache_controller (
  input  logic                  clk,
  input  logic                  rst,

  input  logic                  req_valid,
  output logic                  req_ready,
  input  logic                  req_write,
  input  mesi_pkg::addr_t        req_addr,
  input  mesi_pkg::word_t        req_wdata,

  output logic                  rsp_valid,
  input  logic                  rsp_ready,
  output mesi_pkg::word_t        rsp_rdata,

  output mesi_pkg::index_t       rd_index,
  input  mesi_pkg::tag_t         rd_tag,
  input  mesi_pkg::line_t        rd_data,
  input  mesi_pkg::mesi_state_t  rd_state,
  input  logic                  array_access_ready,

  output mesi_pkg::index_t       wr_index,
  output logic                  tag_we,
  output mesi_pkg::tag_t         wr_tag,
  output logic                  data_we,
  output mesi_pkg::line_t        wr_data,
  output logic                  state_we,
  output mesi_pkg::mesi_state_t  wr_state,

  output logic                  mem_req_valid,
  input  logic                  mem_req_ready,
  output mesi_pkg::bus_cmd_t     mem_req_cmd,
  output logic                  mem_req_write,
  output mesi_pkg::addr_t        mem_req_addr,
  output mesi_pkg::line_t        mem_req_wline,

  input  logic                  mem_rsp_valid,
  output logic                  mem_rsp_ready,
  input  mesi_pkg::line_t        mem_rsp_rline,
  input  logic                  fill_shared
);

  import mesi_pkg::*;

  typedef enum logic [3:0] {
    IDLE,
    LOOKUP,
    WB_REQ,
    WB_RSP,
    FILL_REQ,
    FILL_RSP,
    UPGR_REQ,
    UPGR_RSP,
    RESP
  } controller_state_t;

  controller_state_t state;

  logic saved_write;
  addr_t saved_addr;
  word_t saved_wdata;

  addr_t victim_addr;
  line_t victim_data;

  logic hit;
  logic victim_still_dirty;

  line_t hit_write_line;
  line_t fill_write_line;

  assign rd_index = get_index(saved_addr);
  assign wr_index = get_index(saved_addr);

  assign hit =
    (rd_state != MESI_I) &&
    (rd_tag == get_tag(saved_addr));

  assign victim_still_dirty =
    (rd_state == MESI_M) &&
    (rd_tag == get_tag(victim_addr)) &&
    (rd_index == get_index(victim_addr));

  assign req_ready = !rst && (state == IDLE);
  assign rsp_valid = !rst && (state == RESP);

  // Replace only the requested word, preserving the rest of the line.
  always_comb begin
    hit_write_line = rd_data;

    hit_write_line[
      get_word_sel(saved_addr) * WORD_W +: WORD_W
    ] = saved_wdata;

    fill_write_line = mem_rsp_rline;

    fill_write_line[
      get_word_sel(saved_addr) * WORD_W +: WORD_W
    ] = saved_wdata;
  end

  always_comb begin
    tag_we = 1'b0;
    wr_tag = get_tag(saved_addr);

    data_we = 1'b0;
    wr_data = '0;

    state_we = 1'b0;
    wr_state = MESI_I;

    mem_req_valid = 1'b0;
    mem_req_cmd = BUS_NONE;
    mem_req_write = 1'b0;
    mem_req_addr = line_base(saved_addr);
    mem_req_wline = victim_data;

    mem_rsp_ready = 1'b0;

    if (!rst) begin
      case (state)
        LOOKUP: begin
          // Only E/M allow a silent local write.
          if (
            array_access_ready &&
            hit &&
            saved_write &&
            (rd_state == MESI_E || rd_state == MESI_M)
          ) begin
            data_we = 1'b1;
            wr_data = hit_write_line;

            state_we = 1'b1;
            wr_state = MESI_M;
          end
        end

        WB_REQ: begin
          mem_req_valid =
            array_access_ready && victim_still_dirty;

          mem_req_cmd = BUS_WB;
          mem_req_write = 1'b1;
          mem_req_addr = victim_addr;
        end

        WB_RSP: begin
          mem_rsp_ready = array_access_ready;

          if (
            mem_rsp_valid &&
            mem_rsp_ready &&
            victim_still_dirty
          ) begin
            state_we = 1'b1;
            wr_state = MESI_I;
          end
        end

        FILL_REQ: begin
          mem_req_valid = 1'b1;

          if (saved_write)
            mem_req_cmd = BUS_RDX;
          else
            mem_req_cmd = BUS_RD;
        end

        FILL_RSP: begin
          mem_rsp_ready = array_access_ready;

          if (mem_rsp_valid && mem_rsp_ready) begin
            tag_we = 1'b1;
            data_we = 1'b1;
            state_we = 1'b1;

            if (saved_write) begin
              wr_data = fill_write_line;
              wr_state = MESI_M;
            end else begin
              wr_data = mem_rsp_rline;

              if (fill_shared)
                wr_state = MESI_S;
              else
                wr_state = MESI_E;
            end
          end
        end

        UPGR_REQ: begin
          // A queued upgrade may have been invalidated by a snoop.
          if (
            array_access_ready &&
            hit &&
            rd_state == MESI_S
          ) begin
            mem_req_valid = 1'b1;
            mem_req_cmd = BUS_UPGR;
          end
        end

        UPGR_RSP: begin
          mem_rsp_ready = array_access_ready;

          if (
            mem_rsp_valid &&
            mem_rsp_ready &&
            hit &&
            rd_state == MESI_S
          ) begin
            data_we = 1'b1;
            wr_data = hit_write_line;

            state_we = 1'b1;
            wr_state = MESI_M;
          end
        end

        default: begin end
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= IDLE;

      saved_write <= 1'b0;
      saved_addr <= '0;
      saved_wdata <= '0;

      victim_addr <= '0;
      victim_data <= '0;

      rsp_rdata <= '0;
    end else begin
      case (state)
        IDLE: begin
          if (req_valid && req_ready) begin

            // Simulation-only request validation.
            // synthesis translate_off
            if ($isunknown(req_addr))
              $fatal(
                1,
                "Cache request address contains X/Z"
              );

            if (req_addr[$clog2(WORD_BYTES)-1:0] != '0)
              $fatal(
                1,
                "Cache request must be word-aligned"
              );

            if (req_addr >= MEM_BYTES)
              $fatal(
                1,
                "Cache request address out of range"
              );
            // synthesis translate_on

            saved_write <= req_write;
            saved_addr <= req_addr;
            saved_wdata <= req_wdata;

            state <= LOOKUP;
          end
        end

        LOOKUP: begin
          if (array_access_ready) begin
            if (hit) begin
              if (saved_write && rd_state == MESI_S) begin
                state <= UPGR_REQ;
              end else begin
                if (saved_write)
                  rsp_rdata <= '0;
                else
                  rsp_rdata <= rd_data[
                    get_word_sel(saved_addr) * WORD_W +: WORD_W
                  ];

                state <= RESP;
              end
            end else if (rd_state == MESI_M) begin
              victim_addr <= victim_base(rd_tag, rd_index);
              victim_data <= rd_data;

              state <= WB_REQ;
            end else begin
              state <= FILL_REQ;
            end
          end
        end

        WB_REQ: begin
          if (array_access_ready) begin
            if (!victim_still_dirty)
              state <= LOOKUP;
            else if (mem_req_valid && mem_req_ready)
              state <= WB_RSP;
          end
        end

        WB_RSP: begin
          if (mem_rsp_valid && mem_rsp_ready) begin
            if (!victim_still_dirty)
              $fatal(
                1,
                "Victim changed during an accepted atomic writeback"
              );
            else
              state <= FILL_REQ;
          end
        end

        FILL_REQ: begin
          if (mem_req_valid && mem_req_ready)
            state <= FILL_RSP;
        end

        FILL_RSP: begin
          if (mem_rsp_valid && mem_rsp_ready) begin
            if (saved_write)
              rsp_rdata <= '0;
            else
              rsp_rdata <= mem_rsp_rline[
                get_word_sel(saved_addr) * WORD_W +: WORD_W
              ];

            state <= RESP;
          end
        end

        UPGR_REQ: begin
          if (array_access_ready) begin
            if (!hit || rd_state != MESI_S) begin
              // Retry lookup if a snoop invalidated the queued upgrade.
              state <= LOOKUP;
            end else if (mem_req_valid && mem_req_ready) begin
              state <= UPGR_RSP;
            end
          end
        end

        UPGR_RSP: begin
          if (mem_rsp_valid && mem_rsp_ready) begin
            if (!hit || rd_state != MESI_S) begin
              $fatal(
                1,
                "Shared line lost during granted upgrade"
              );
            end else begin
              rsp_rdata <= '0;
              state <= RESP;
            end
          end
        end

        RESP: begin
          if (rsp_valid && rsp_ready)
            state <= IDLE;
        end

        default:
          $fatal(1, "Invalid cache-controller state");
      endcase
    end
  end

endmodule