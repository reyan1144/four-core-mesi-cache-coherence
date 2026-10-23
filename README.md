# Four-Core MESI Cache-Coherence System

A SystemVerilog implementation of a four-core cache-coherence subsystem using the MESI protocol.

The system connects four private, direct-mapped, write-back caches through an atomic round-robin snooping bus to shared backing memory. Processor-side request interfaces are exercised using simulation testbenches; the project does not implement four complete CPU cores.

## Features

- MESI states: Modified, Exclusive, Shared, and Invalid.
- Private write-back, write-allocate caches.
- Processor-side word reads and writes.
- BusRd, BusRdX, BusUpgr, and writeback transactions.
- Round-robin arbitration with ownership retained throughout each atomic bus transaction.
- Clean-line sharing and shared-copy invalidation.
- Dirty-line intervention and eviction writeback.
- Pending-upgrade revalidation after snoop invalidation.
- Cancellation of obsolete pending dirty writebacks.
- Valid/ready handshakes and response backpressure.
- Configurable backing-memory request and response delays.
- Directed and concurrent randomized verification.

## Configuration

| Parameter | Value |
|---|---:|
| Processor-side interfaces | 4 |
| Address width | 32 bits |
| Word width | 32 bits |
| Cache-line size | 16 bytes |
| Words per cache line | 4 |
| Cache lines per private cache | 16 |
| Data capacity per private cache | 256 bytes |
| Cache organization | Direct-mapped |
| Backing-memory capacity | 4 KiB |
| Write policy | Write-back, write-allocate |

Configuration constants and shared types are defined in `mesi_pkg.sv`.

## Architecture

```text
Processor request interfaces
       |       |       |       |
      L1 0    L1 1    L1 2    L1 3
       \       |       |       /
        Atomic snooping coherence bus
          Round-robin arbitration
                    |
             Shared backing memory
```

Each private cache contains:

- Cache tag, data, and MESI-state arrays.
- A local controller handling processor requests.
- A snoop controller handling transactions from other caches.
- Array-access coordination between local and snoop operations.

### Coherence behavior

- A read miss with no other cached copy fills the line in E.
- A read miss with another cached copy fills the line in S.
- A write hit in E transitions silently to M.
- A write hit in M updates the line without a bus transaction.
- A write hit in S requests BusUpgr and invalidates other copies.
- A write miss requests BusRdX to obtain exclusive ownership.
- A remote read of an M line causes a dirty flush and downgrade to S.
- A remote ownership request to an M line causes a dirty flush and invalidation.
- Replacing an M line writes the victim back to memory.

Dirty intervention uses a flush-to-memory path. The requester subsequently obtains the updated line from backing memory; there is no direct cache-to-cache data-bypass path.

## RTL Modules

| File | Purpose |
|---|---|
| `mesi_pkg.sv` | Configuration, types, MESI states, bus commands, and address helpers |
| `cache_arrays.sv` | Cache data, tags, and MESI-state storage |
| `cache_controller.sv` | Processor request handling, lookup, fill, upgrade, and eviction |
| `snoop_controller.sv` | Remote snoop handling, dirty intervention, and state updates |
| `l1_cache.sv` | Integration of local controller, snooper, and arrays |
| `bus_arbiter.sv` | Round-robin bus ownership |
| `coherence_bus_ctrl.sv` | Atomic coherence-transaction sequencing |
| `main_memory.sv` | Shared line-based memory with configurable delays |
| `four_core_top.sv` | Integration of four private caches, bus, and memory |

## Repository Layout

```text
rtl/
    mesi_pkg.sv
    cache_arrays.sv
    cache_controller.sv
    snoop_controller.sv
    l1_cache.sv
    bus_arbiter.sv
    coherence_bus_ctrl.sv
    main_memory.sv
    four_core_top.sv

tb/
    mesi_monitor.sv
    tb_directed_mesi.sv
    mesi_random_monitor.sv
    tb_random_mesi.sv
```

## Running in Vivado

The project was simulated using Vivado/XSim 2025.2.

### Setup

1. Create a Vivado RTL project.
2. Add the files in `rtl/` as Design Sources.
3. Ensure `mesi_pkg.sv` compiles before modules importing it.
4. Set the design top to `four_core_top`.
5. Add the files in `tb/` as Simulation Sources.

No FPGA programming or implementation flow is required for behavioral simulation.

### Directed verification

Set the simulation top to:

```text
tb_directed_mesi
```

Launch behavioral simulation and run:

```tcl
run -all
```

Expected completion markers:

```text
PASS: All 11 directed MESI tests passed.
Total completed core operations=96
MONITOR PASS: reads=66 stores=30 responses=96 invariant_samples=996
```

### Randomized verification

Set the simulation top to:

```text
tb_random_mesi
```

The test runs 250 operations per interface, for 1,000 operations total, with all four drivers active concurrently.

Launch behavioral simulation and run:

```tcl
run -all
```

The default seed is configured in the testbench:

```systemverilog
seed = 32'd12345;
```

To test another seed, change this value, save the file, and relaunch behavioral simulation.

Verified seeds:

```text
12345
42
2026
```

Example completion marker:

```text
PASS: seed=12345 all 1000 concurrent core operations completed
```

Traffic counts may differ between seeds. A passing run requires completion of all operations, the required stress conditions, and no fatal verification failures.

## Verification

### Directed scenarios

The directed suite covers:

1. Read miss to E and subsequent same-line read hits.
2. Silent E-to-M and M write hits.
3. Shared copies across two and four caches.
4. Shared-writer invalidation.
5. Remote reads of modified data.
6. Dirty ownership transfer with preservation of other words.
7. Dirty eviction and reload.
8. Four-core write ping-pong.
9. False sharing between different words in one cache line.
10. Same-index, different-tag conflict replacements.
11. Pending-upgrade invalidation and retry as BusRdX.

### Randomized stress

The randomized suite exercises:

- Concurrent processor requests.
- Reads and writes to the same word.
- Different-word accesses within the same line.
- Conflicting cache indices.
- Addresses spread throughout backing memory.
- Core-response backpressure.
- Memory request delays of 0–5 cycles.
- Additional memory response delays of 0–9 cycles.
- Dirty intervention and eviction traffic.

### Scoreboard and assertions

The simulation monitors check:

- Read data against a reference model.
- Correspondence between accepted requests and committed operations.
- Response values and stability under backpressure.
- Valid cached data against the reference model.
- Single-writer/multiple-reader and E/M exclusivity.
- Duplicate or unrequested commits and responses.
- Outstanding operations at test completion.
- Legal local-controller, snoop-controller, and bus-controller FSM transitions.

The reference model updates at observed architectural store-commit events. Read expectations are captured at the read's data-capture edge rather than at delayed response acceptance.

## Recorded Results

The post-lint-fix manual system regression passed:

| Test | Completed operations |
|---|---:|
| Directed suite | 96 |
| Random seed 12345 | 1,000 |
| Random seed 42 | 1,000 |
| Random seed 2026 | 1,000 |
| **Total** | **3,096** |

The recorded default-seed random run covered:

| FSM | Observed / listed non-self transitions |
|---|---:|
| Local cache controller | 14 / 14 |
| Snoop controller | 8 / 8 |
| Coherence bus controller | 11 / 11 |

Coverage is aggregated across cache instances where applicable.

The directed suite alone covers 13/14 local-controller edges. Its missing `WB_REQ → LOOKUP` writeback-cancellation edge is exercised by the randomized suite.

These figures describe the explicitly tracked non-self FSM edges. They do not imply exhaustive functional coverage or formal verification.

## Lint Review

Vivado's synthesis-based linter completed after simulation-only request checks were enclosed in:

```systemverilog
// synthesis translate_off
// simulation-only validation
// synthesis translate_on
```

Three unused-bit/signal findings were reviewed and retained:

| Finding | Interpretation |
|---|---|
| Upper bits of arbiter `candidate` are unread | Wide temporary arithmetic is used, while the selected core ID requires two bits |
| `grants` is unread in `four_core_top` | Integration routes transactions using `owner_valid` and `owner_id` |
| `local_mem_req_write` is unread in `l1_cache` | Bus command encoding identifies the transaction type |

The design is not claimed to be warning-free.

## Scope and Limitations

- Processor interfaces are request drivers, not complete CPU implementations.
- Each private cache supports one outstanding processor operation.
- The bus handles one atomic coherence transaction at a time.
- The caches are direct-mapped.
- Processor accesses are aligned, full-word operations.
- Memory transfers operate on complete cache lines.
- Backing memory is a simplified model with reset-to-zero contents.
- There is no direct cache-to-cache data bypass.
- Verification is simulation-based, not a formal proof.
- The automated regression script was not adopted; regression was run manually.
- FPGA placement, routing, timing closure, and board validation have not been established.

## Possible Extensions

- Parameterized cache capacity and associativity.
- Byte-enable and partial-word writes.
- Additional functional coverage and automated regression.
- More randomized seeds and latency configurations.
- Formal coherence-property checking.
- Direct cache-to-cache data forwarding.
- Integration with processor cores.
- FPGA resource and timing characterization.
