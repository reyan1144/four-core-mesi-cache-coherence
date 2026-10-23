`timescale 1ns / 1ps

module mesi_monitor (
  input logic clk,
  input logic rst
);
  import mesi_pkg::*;

  localparam int WORD_COUNT = MEM_BYTES / WORD_BYTES;

  word_t reference_words [0:WORD_COUNT-1];
  word_t expected_response [0:NUM_CORES-1];
  word_t stalled_data [0:NUM_CORES-1];

  addr_t issued_addr [0:NUM_CORES-1];
  word_t issued_data [0:NUM_CORES-1];
  logic issued_write [0:NUM_CORES-1];

  logic [NUM_CORES-1:0] pending, result_ready, stalled;
  logic history_valid;

  int previous_local [0:NUM_CORES-1];
  int previous_snoop [0:NUM_CORES-1];
  int previous_bus;

  // Coverage accumulates across the directed tests and their resets.
  bit local_edges [0:8][0:8];
  bit snoop_edges [0:5][0:5];
  bit bus_edges [0:7][0:7];

  int unsigned stores_checked = 0;
  int unsigned reads_checked = 0;
  int unsigned responses_checked = 0;
  int unsigned invariant_samples = 0;

  wire [NUM_CORES-1:0] req_fire, rsp_valid, rsp_ready;
  wire [NUM_CORES-1:0] store_commit, read_commit, saved_write;

  wire [NUM_CORES-1:0][ADDR_W-1:0] operation_addr;

  wire [NUM_CORES-1:0][WORD_W-1:0] store_value;
  wire [NUM_CORES-1:0][WORD_W-1:0] read_value;
  wire [NUM_CORES-1:0][WORD_W-1:0] response_value;

  wire [3:0] local_state [0:NUM_CORES-1];
  wire [2:0] snoop_state [0:NUM_CORES-1];

  wire [1:0] cache_state [0:NUM_CORES-1][0:NUM_LINES-1];
  wire [TAG_W-1:0] cache_tag [0:NUM_CORES-1][0:NUM_LINES-1];
  wire [LINE_W-1:0] cache_data [0:NUM_CORES-1][0:NUM_LINES-1];

  wire [2:0] bus_state =
    tb_directed_mesi.dut.bus_controller.state;

  // Simulation-only connections to the existing hierarchy.
  generate
    for (genvar c = 0; c < NUM_CORES; c++) begin : taps
      assign req_fire[c] =
        tb_directed_mesi.req_valid[c] &&
        tb_directed_mesi.req_ready[c];

      assign rsp_valid[c] = tb_directed_mesi.rsp_valid[c];
      assign rsp_ready[c] = tb_directed_mesi.rsp_ready[c];
      assign response_value[c] = tb_directed_mesi.rsp_rdata[c];

      assign local_state[c] =
        tb_directed_mesi.dut.caches[c].cache_inst.local_controller.state;

      assign snoop_state[c] =
        tb_directed_mesi.dut.caches[c].cache_inst.snooper.state;

      assign operation_addr[c] =
        tb_directed_mesi.dut.caches[c].cache_inst.local_controller.saved_addr;

      assign store_value[c] =
        tb_directed_mesi.dut.caches[c].cache_inst.local_controller.saved_wdata;

      assign saved_write[c] =
        tb_directed_mesi.dut.caches[c].cache_inst.local_controller.saved_write;

      // Read fills also write the array, so qualify with saved_write.
      assign store_commit[c] =
        saved_write[c] &&
        tb_directed_mesi.dut.caches[c].cache_inst.local_data_we;

      // Read capture occurs on a hit or an accepted fill response.
      assign read_commit[c] =
        !saved_write[c] &&
        (
          (
            local_state[c] == 1 &&
            tb_directed_mesi.dut.caches[c].cache_inst.allow_fill &&
            tb_directed_mesi.dut.caches[c].cache_inst.local_controller.hit
          ) ||
          (
            local_state[c] == 5 &&
            tb_directed_mesi.dut.caches[c].cache_inst.local_controller.mem_rsp_valid &&
            tb_directed_mesi.dut.caches[c].cache_inst.local_mem_rsp_ready
          )
        );

      assign read_value[c] =
        (local_state[c] == 1) ?
        tb_directed_mesi.dut.caches[c].cache_inst.local_rd_data[
          get_word_sel(operation_addr[c]) * WORD_W +: WORD_W
        ] :
        tb_directed_mesi.dut.caches[c].cache_inst.local_controller.mem_rsp_rline[
          get_word_sel(operation_addr[c]) * WORD_W +: WORD_W
        ];

      for (genvar n = 0; n < NUM_LINES; n++) begin : entries
        assign cache_state[c][n] =
          tb_directed_mesi.dut.caches[c].cache_inst.arrays.state_array[n];

        assign cache_tag[c][n] =
          tb_directed_mesi.dut.caches[c].cache_inst.arrays.tag_array[n];

        assign cache_data[c][n] =
          tb_directed_mesi.dut.caches[c].cache_inst.arrays.data_array[n];
      end
    end
  endgenerate

  // kind 0: local controller; kind 1: snooper; kind 2: bus controller.
  // State numbers match the existing RTL enum declaration order.
  function automatic bit legal_edge(
    input int kind,
    input int a,
    input int b
  );
    if (a == b) return 1;

    case (kind)
      0: case (a)
        0: return b == 1;
        1: return b == 2 || b == 4 || b == 6 || b == 8;
        2: return b == 1 || b == 3;
        3: return b == 4;
        4: return b == 5;
        5: return b == 8;
        6: return b == 1 || b == 7;
        7: return b == 8;
        8: return b == 0;
        default: return 0;
      endcase

      1: case (a)
        0: return b == 1;
        1: return b == 2 || b == 4 || b == 5;
        2: return b == 3;
        3: return b == 4;
        4: return b == 5;
        5: return b == 0;
        default: return 0;
      endcase

      2: case (a)
        0: return b == 1 || b == 5;
        1: return b == 2;
        2: return b == 3 || b == 5 || b == 7;
        3: return b == 4;
        4: return b == 2;
        5: return b == 6;
        6: return b == 7;
        7: return b == 0;
        default: return 0;
      endcase

      default: return 0;
    endcase
  endfunction

  // Sample handshake and commit events before RTL nonblocking updates.
  always @(posedge clk) begin
    if (rst) begin
      for (int w = 0; w < WORD_COUNT; w++)
        reference_words[w] = '0;

      pending = '0;
      result_ready = '0;
      stalled = '0;
      history_valid = 0;
    end else begin
      for (int c = 0; c < NUM_CORES; c++) begin
        if (
          $isunknown(local_state[c]) || local_state[c] > 8 ||
          $isunknown(snoop_state[c]) || snoop_state[c] > 5
        )
          $fatal(
            1, "MONITOR: unknown/invalid FSM state C%0d", c
          );

        if (history_valid) begin
          if (!legal_edge(0, previous_local[c], local_state[c]))
            $fatal(
              1,
              "MONITOR: illegal local FSM edge C%0d %0d->%0d",
              c, previous_local[c], local_state[c]
            );

          if (!legal_edge(1, previous_snoop[c], snoop_state[c]))
            $fatal(
              1, "MONITOR: illegal snoop FSM edge C%0d", c
            );

          if (previous_local[c] != local_state[c])
            local_edges[previous_local[c]][local_state[c]] = 1;

          if (previous_snoop[c] != snoop_state[c])
            snoop_edges[previous_snoop[c]][snoop_state[c]] = 1;
        end

        previous_local[c] = int'(local_state[c]);
        previous_snoop[c] = int'(snoop_state[c]);

        if (req_fire[c]) begin
          if (pending[c])
            $fatal(
              1, "MONITOR: overlapping core request C%0d", c
            );

          issued_addr[c] = tb_directed_mesi.req_addr[c];
          issued_data[c] = tb_directed_mesi.req_wdata[c];
          issued_write[c] = tb_directed_mesi.req_write[c];

          if (
            $isunknown(issued_addr[c]) ||
            $isunknown(issued_write[c]) ||
            issued_addr[c] >= MEM_BYTES ||
            issued_addr[c] % WORD_BYTES != 0
          )
            $fatal(
              1, "MONITOR: invalid accepted request C%0d", c
            );

          if (issued_write[c] && $isunknown(issued_data[c]))
            $fatal(
              1, "MONITOR: unknown store value C%0d", c
            );

          pending[c] = 1;
          result_ready[c] = 0;
        end

        if (
          stalled[c] &&
          (
            rsp_valid[c] !== 1'b1 ||
            response_value[c] !== stalled_data[c]
          )
        )
          $fatal(
            1,
            "MONITOR: response changed under backpressure C%0d",
            c
          );

        if (rsp_valid[c]) begin
          if (!pending[c] || !result_ready[c])
            $fatal(
              1,
              "MONITOR: response without committed operation C%0d",
              c
            );

          if (response_value[c] !== expected_response[c])
            $fatal(
              1,
              "MONITOR: response mismatch C%0d expected=%h actual=%h",
              c, expected_response[c], response_value[c]
            );

          if (rsp_ready[c]) begin
            pending[c] = 0;
            result_ready[c] = 0;
            responses_checked++;
          end
        end

        stalled[c] = rsp_valid[c] && !rsp_ready[c];
        stalled_data[c] = response_value[c];
      end

      if ($isunknown(bus_state))
        $fatal(1, "MONITOR: unknown bus FSM state");

      if (history_valid) begin
        if (!legal_edge(2, previous_bus, bus_state))
          $fatal(
            1,
            "MONITOR: illegal bus FSM edge %0d->%0d",
            previous_bus, bus_state
          );

        if (previous_bus != bus_state)
          bus_edges[previous_bus][bus_state] = 1;
      end

      previous_bus = int'(bus_state);
      history_valid = 1;

      // Check a read when data is captured, not when its response is accepted.
      for (int c = 0; c < NUM_CORES; c++) begin
        if (read_commit[c]) begin
          if (
            operation_addr[c] !== issued_addr[c] ||
            issued_write[c] !== 1'b0
          )
            $fatal(
              1,
              "MONITOR: read differs from accepted request C%0d",
              c
            );

          if (!pending[c] || result_ready[c])
            $fatal(
              1, "MONITOR: duplicate/unrequested read C%0d", c
            );

          expected_response[c] =
            reference_words[issued_addr[c] / WORD_BYTES];

          if (read_value[c] !== expected_response[c])
            $fatal(
              1,
              "MONITOR: stale read C%0d addr=%h expected=%h actual=%h",
              c, operation_addr[c],
              expected_response[c], read_value[c]
            );

          result_ready[c] = 1;
          reads_checked++;
        end
      end

      // Update expected memory at the architectural store-commit edge.
      for (int c = 0; c < NUM_CORES; c++) begin
        if (store_commit[c]) begin
          if (
            operation_addr[c] !== issued_addr[c] ||
            issued_write[c] !== 1'b1 ||
            store_value[c] !== issued_data[c]
          )
            $fatal(
              1,
              "MONITOR: store differs from accepted request C%0d",
              c
            );

          if (!pending[c] || result_ready[c])
            $fatal(
              1, "MONITOR: duplicate/unrequested store C%0d", c
            );

          reference_words[issued_addr[c] / WORD_BYTES] =
            issued_data[c];

          expected_response[c] = '0;
          result_ready[c] = 1;
          stores_checked++;
        end
      end
    end
  end

  // Check settled cache arrays after rising-edge commits.
  always @(negedge clk) begin : invariants
    addr_t address;
    int word_index;

    if (!rst && history_valid) begin
      invariant_samples++;

      for (int c = 0; c < NUM_CORES; c++) begin
        for (int n = 0; n < NUM_LINES; n++) begin
          if ($isunknown(cache_state[c][n]))
            $fatal(
              1,
              "MONITOR: unknown MESI state C%0d index=%0d",
              c, n
            );

          if (cache_state[c][n] != MESI_I) begin
            if ($isunknown(cache_tag[c][n]))
              $fatal(
                1, "MONITOR: valid line has unknown tag"
              );

            address = victim_base(
              cache_tag[c][n], index_t'(n)
            );

            if (address >= MEM_BYTES)
              $fatal(
                1, "MONITOR: invalid cached address"
              );

            word_index = int'(address / WORD_BYTES);

            for (int w = 0; w < WORDS_PER_LINE; w++) begin
              if (
                cache_data[c][n][w*WORD_W +: WORD_W] !==
                reference_words[word_index+w]
              )
                $fatal(
                  1,
                  "MONITOR: cached data mismatch C%0d addr=%h word=%0d",
                  c, address, w
                );
            end

            // Multiple copies of one line are legal only when all are S.
            for (int d = c+1; d < NUM_CORES; d++) begin
              if (
                cache_state[d][n] != MESI_I &&
                cache_tag[d][n] == cache_tag[c][n]
              ) begin
                if (
                  cache_state[c][n] != MESI_S ||
                  cache_state[d][n] != MESI_S
                )
                  $fatal(
                    1,
                    "MONITOR: SWMR/exclusivity violation C%0d C%0d addr=%h",
                    c, d, address
                  );
              end
            end
          end
        end
      end
    end
  end

  task automatic report;
    int hits, possible;

    if (pending !== '0)
      $fatal(1, "MONITOR: unfinished core operations");

    $display(
      "MONITOR PASS: reads=%0d stores=%0d responses=%0d invariant_samples=%0d",
      reads_checked, stores_checked,
      responses_checked, invariant_samples
    );

    for (int kind = 0; kind < 3; kind++) begin
      hits = 0;
      possible = 0;

      for (int a = 0; a < 9; a++) begin
        for (int b = 0; b < 9; b++) begin
          if (
            a != b &&
            legal_edge(kind, a, b) &&
            (
              kind == 0 ||
              (kind == 1 && a < 6 && b < 6) ||
              (kind == 2 && a < 8 && b < 8)
            )
          ) begin
            possible++;

            case (kind)
              0: begin
                if (local_edges[a][b])
                  hits++;
                else
                  $display(
                    "COVERAGE GAP: local %0d -> %0d", a, b
                  );
              end

              1: begin
                if (snoop_edges[a][b])
                  hits++;
                else
                  $display(
                    "COVERAGE GAP: snoop %0d -> %0d", a, b
                  );
              end

              2: begin
                if (bus_edges[a][b])
                  hits++;
                else
                  $display(
                    "COVERAGE GAP: bus %0d -> %0d", a, b
                  );
              end
            endcase
          end
        end
      end

      $display(
        "FSM COVERAGE kind=%0d: %0d/%0d non-self edges",
        kind, hits, possible
      );
    end
  endtask

endmodule