# Signal graph architecture

A text-specified DSP flow graph that turns raw sensor columns into synthesized
streams. The graph runs in a process that is, to everything else, an ordinary
TIO device: it mounts the sensors, publishes its own results alongside them, and
exposes its parameters as RPCs. Whether it runs inside the app or on another
machine is a URL.

Status: M0 to M6 of §17 are implemented, and M7 but for its last step, the first four in `rust/tio-dsp`. M0 is the engine:
the signal model, the node, stage and kernel traits, lane expansion, the
scheduler and the invariance harness. M1 is the language front end: lexer,
lossless syntax tree, parser, checker and diagnostics, behind `tiodsp check`
and `tiodsp graph --dot`. M2 joins them: filter design, `decimate`, `resample`
and `align`, lowering a checked program into a graph, and `tiodsp run --log`.
M3 is the device: `tiodsp serve` mounts sensors, publishes the outputs beside
them at `/255`, and answers for the params and the spec over RPC. M4 connects
the app: every session mounts its sensor at `/0`, and a document can be given
a spec, which the bridge hosts in process. M5 is the editor: text beside the
graph it describes, every canvas gesture a splice of the text, each change put
to the running graph, which restarts only what the change touched. M6 is the
figure, `tiodsp graph --typst` and `--pdf`, and the private device: a build
that adds functions of its own to the public ones, worked through in
`rust/examples/private-dsp` and `docs/private-dsp-device.md`. M7 makes every
function in the table run, the adaptive decorrelators among them, adds
zero-phase filtering, `detrend` and `psd` for recordings, and `fn`. What is
left of it is the move upstream, which has not been made. §18 lists what M2 to
M7 left out. Written 10 September 2026.

## Decisions

| | |
|---|---|
| **Topology** | The DSP is a TIO device. Sensors at `/0`, `/1`, … always; graph output at `/255`. One connection, one tree (§2). |
| **Control surface** | Params, the spec and diagnostics travel as RPCs and log packets. No new app mechanism (§10). |
| **Private modules** | A private module is a TIO device. Nothing to invent — no plugin protocol, no manifest, no lockfile (§11). |
| **Time base** | Explicit rate domains. Align once, up front, into a common grid. Crossing rates without a written `decimate` or `resample` is a compile error (§5). |
| **Parallelism** | Work-stealing pool over *(node × channel bundle)* tasks. Scheduling is nondeterministic; results are not (§8). |
| **Language** | Pipeline DSL over a lossless syntax tree the editor splices rather than regenerates (§6). |
| **Channel matching** | By name, never by position. |

## Contents

1. [What already exists](#1-what-already-exists)
2. [Topology: one tree, two branches](#2-topology-one-tree-two-branches)
3. [Where the code lives](#3-where-the-code-lives)
4. [The signal model](#4-the-signal-model)
5. [Rate domains and alignment](#5-rate-domains-and-alignment)
6. [The language](#6-the-language)
7. [Compilation and diagnostics](#7-compilation-and-diagnostics)
8. [Execution, threading, and cores](#8-execution-threading-and-cores)
9. [The node library](#9-the-node-library)
10. [The control surface](#10-the-control-surface)
11. [Private modules](#11-private-modules)
12. [Text and graph, both ways](#12-text-and-graph-both-ways)
13. [Rendering the graph](#13-rendering-the-graph)
14. [The editor surface](#14-the-editor-surface)
15. [The CLI](#15-the-cli)
16. [Proving it correct](#16-proving-it-correct)
17. [Milestones](#17-milestones)
18. [Open calls and risks](#18-open-calls-and-risks)

---

## 1. What already exists

Most of the hard parts have precedent in this tree. The topology of §2 leans on
the last three rows especially.

| What | Where | Why it matters here |
|---|---|---|
| `ColumnOp` | `twinleaf/src/data/pipeline.rs` | An incremental per-column op with `reset` / `update_batch` / `output`. The `Node` trait is this widened to N inputs and M outputs. |
| `ColumnProcessor` | `twinleaf/src/data/pipeline.rs` | Already solves replay-after-restart and retention overrun by resetting on a changed `Generations::stream`. The graph's run-boundary rule is the same rule. |
| `SampleBatch` | `twinleaf/src/data/sample.rs` | Columnar, timestamped, generation-stamped, with per-column metadata. The source-node input and the sink-node output. |
| `BatchCoalescer` | `twinleaf/src/data/coalesce.rs` | Already merges small live batches into larger chunks — the amortization the parallel scheduler needs in front of it (§8). |
| `ColumnFilter` | `twinleaf/src/data/filter.rs` | Already defines the `/{route}/{stream}/{column}` path grammar, where naming a stream selects every column under it. The DSL adopts it verbatim, and `/255/**` addresses graph output for free. |
| `Welch` | `twinleaf/src/data/ops/welch.rs` | A working `ColumnOp` for Welch ASD, now in the twinleaf 2.0 library. The bridge uses it directly, so `twinleaf-tools` is no longer a bridge dependency. |
| **Multi-sensor mount** | `twinleaf/src/proxy/mod.rs` (`Layout`) | The 2.0 proxy mounts several sensors as one device tree, sensor *k* at `/k`, and the bridge opens a `Layout` for it. `tiodsp` **is** this, extended. See §2. |
| **RPC slider convention** | `Sources/Twinleaf/MainWindow.swift:1097` | The slider tray already looks for a sibling `<name>.max` RPC and computes a default when there is none. A DSP device exposing `dsp.line` and `dsp.line.max` gets a working slider with no app change. |
| **Chunked RPC transfer** | `twinleaf/src/firmware/mod.rs:22` | Firmware upload already moves bulk data through RPCs in 288-byte chunks with an offset/size/crc envelope and two in flight. `dsp.spec` follows the same shape (§10). |

## 2. Topology: one tree, two branches

Everything the app talks to is a TIO device, the DSP included. That one decision
deletes most of the machinery an earlier draft of this plan needed: there is no
plugin protocol, no node manifest, no lockfile, no synthetic-stream injection,
and no bespoke parameter UI. TIO already is all of those things.

Route layout:

```text
  /0, /1, …     sensors, always, even when only one is connected
  /255          graph output
```

### The sidecar is the mount

`start_multi_sensor_mount` already binds a loopback port and serves several
sensors as one tree. `tiodsp` extends exactly that: mount the sensors, run the
graph, publish the results at `/255`, serve the whole tree on one port.

```text
                     ┌──────────────────────────────────────────┐
   sensor A ────────►│ tiodsp                                   │
   tcp://…           │                                          │
                     │   mounts sensors ──────────► /0  /1  …   │
   sensor B ────────►│                                          │──► app
   serial://…        │   runs the graph ──────────► /255        │    one connection
                     │                                          │
                     │   params, spec, diagnostics ─► RPCs      │
                     └──────────────────────────────────────────┘
```

The app makes one connection and sees both branches. Sensor data crosses the
wire once, not twice, because the DSP is upstream of the app rather than beside
it. Nothing in the app's connection, plotting, logging or export path changes:
`/255/gradient/x` is a column like any other.

### In-app and off-app differ only by URL

```text
  in-app                                off-app
  ┌────────────────────────────┐        ┌──────────────┐    ┌──────────────────┐
  │ Twinleaf.app               │        │ Twinleaf.app │───►│ private tiodsp   │
  │  ┌──────────────────────┐  │        └──────────────┘    │ on another host  │
  │  │ tiodsp on a thread   │  │                            └──────────────────┘
  │  │ loopback listener    │  │         tcp://dsp.lab.local:7855
  │  └──────────────────────┘  │
  └────────────────────────────┘
     tcp://127.0.0.1:<port>
```

In-app means the engine runs on a thread inside the Rust core, serving loopback
TCP — a listener in our own process, not a spawned subprocess, so iPadOS works
the same way as macOS. The app's connection code cannot tell the two apart, and
should not be able to.

### Why `/0` even for a single device

Today a direct connection lands at the root, and the mount is used only when
several sensors are combined. Making `/0` universal costs one hop of route depth
(eight are available) and a migration for saved documents holding root-relative
column keys. It buys the thing that matters: **a spec, a pane selection or a
saved layout written against `/0/field` keeps working when a second sensor is
attached, and one written against `/field` does not.** Uniform depth also means
`ColumnFilter` patterns behave the same in every session.

### Why `/255`

A route hop is a plain `u8` with no value validation. `DeviceRoute::from_hops`
and `push` check depth only, `from_str` parses each segment as `u8`, and
`Display` writes it back, so `/255` round-trips exactly. `MAX_ROUTING_SIZE` is 8,
so depth is no constraint.

The number is an allocation, not a meaning. `tiodsp` claims `/255` by default and
descends on collision, and the device's own metadata record says what it is, so a
reader identifies graph output from the data rather than from a memorized hop. A
hub that someday enumerates a real device at 255 is then a non-event.

One hard constraint to respect: `StreamId` is 1–127 and `StreamId::new` is a
`const fn` with an `assert!`, not a fallible constructor. A graph with more than
127 outputs needs a second route, and the sink must never hand it an unvalidated
count — that is a panic, in the ingest path.

## 3. Where the code lives

`rust/` becomes a two-member Cargo workspace. `tio-dsp` depends on `twinleaf` and
on nothing from the app; it is both a library and the `tiodsp` binary. The bridge
links it only to host the in-app instance on a thread, and to reuse its front end
for editor syntax highlighting (§14).

```toml
# rust/Cargo.toml
[workspace]
members = ["tio-bridge", "tio-dsp"]
resolver = "2"

# rust/tio-dsp/Cargo.toml
[lib]   name = "tio_dsp"
[[bin]] name = "tiodsp"

[features]
default = []
typst   = ["dep:typst", "dep:typst-svg", "dep:typst-pdf"]  # §13

[dependencies]
twinleaf = { version = "2.0", path = "../../vendor/twinleaf-rust/twinleaf" }
rayon    = "1"
# No app types in the public API, so the crate lifts into the twinleaf-rust
# workspace as `twinleaf-dsp` unchanged once the language stops moving.
```

Because the engine is reached over TIO rather than through a function call, the
same three drivers produce the same bytes:

```text
  live session          ┐
  Device::samples()     │
                        │      ┌────────────────────────┐
  log playback          ├─────►│ tio-dsp                │
  LogIndex::batches()   │      │   Graph::tick()        │──► identical output
                        │      │   no wall-clock reads  │    on any core count
  tiodsp run            ┘      │   fixed-shape sums     │
  headless, same call          └────────────────────────┘
```

The engine never reads a clock. Every timestamp comes from the data, block
segmentation is an input rather than a scheduling accident, and every cross-lane
sum has a fixed reduction shape, so thread count is not an input either. The app
is now entirely out of this loop, which makes `tiodsp` alone the unit under test.

## 4. The signal model

An edge carries a stream of `Block`s: contiguous, uniformly sampled,
multi-channel. Multi-channel is not a convenience. `/0/field` *is* three
channels, and a filter applied to it filters x, y and z with one set of
coefficients. That broadcast is what makes "apply the same filters to the second
stream" a one-line change rather than a copied subgraph, and it is where §8 finds
most of its parallelism.

```rust
/// A contiguous run of uniformly sampled, multi-channel data.
pub struct Block {
    /// Which rate domain these samples live in. Two blocks sharing a
    /// `DomainId` are guaranteed to have coincident sample instants; that
    /// is the whole point of §5.
    pub domain: DomainId,
    /// Continuity token. A change means "reset all downstream state", the
    /// same contract a bumped `Generations::stream` carries today.
    pub run: RunId,
    /// Index of frame 0 within the domain's global sample numbering.
    /// Integer, not float: two blocks in one domain align by index, and no
    /// floating-point comparison is involved in deciding that.
    pub first: u64,
    pub frames: usize,
    /// Names, units, provenance. Shared across every block of one edge.
    pub channels: Arc<ChannelSet>,
    /// Channel-major: `data[c * frames + i]`. Planar, not interleaved,
    /// because every op is per-channel and wants a contiguous inner loop,
    /// and because it makes the channel axis the parallel axis.
    pub data: Vec<f64>,
}

/// A rate domain: one timescale, one rate, one sample grid. Established by a
/// source or by an `align`, and never implicitly crossed.
pub struct Domain {
    pub id: DomainId,
    pub epoch: proto::sync::Epoch,   // unix | systime | zero | invalid
    pub session: SessionId,          // timebase instance
    pub rate: f64,                   // samples per second
    pub origin: f64,                 // time of sample 0, on `epoch`
}

/// Static type of an edge, resolved when the graph is built.
pub struct SignalType {
    pub domain: DomainId,
    pub channels: Arc<ChannelSet>,   // names are load-bearing, see §6
    pub units: Units,
}
```

**Why frames are indexed, not timestamped.** Once alignment happens once, up
front, every downstream block in a domain is addressable by integer sample index.
Elementwise ops become index arithmetic with no float comparison, no tolerance
constant, and no per-node interpolation. Timestamps still exist —
`origin + first / rate` reconstructs them exactly — but nothing in the hot path
consults them.

## 5. Rate domains and alignment

A domain is one timescale, one rate, one sample grid. Signals within a domain
have coincident sample instants by construction, so subtracting them is index
arithmetic: no buffering, no interpolation, no per-node cost. Crossing domains
requires a node you wrote yourself.

This replaces an earlier design in which the compiler inserted an alignment node
at every multi-input site. That version paid interpolation cost at every
junction, made alignment invisible in the text the user reads, and left the door
open to filtering two arms at different rates, which silently destroys
common-mode rejection. Domains close that door structurally: arms at different
rates cannot meet at a subtraction at all, because they are not the same type.

```text
REJECTED — separate domains, so the subtraction has no meaning

  /0/field ──► notch → bandpass ──┐
  3 ch, 1 kHz                     ├──► ( − )   error[E0412]: domain mismatch
  /1/field ──► notch → bandpass ──┘            left arm 1 kHz, right arm 500 Hz
  3 ch, 500 Hz


ADOPTED — one align, one domain, one filter chain over all six channels

  /0/field ──► decimate(2) ──┐
  3 ch, 1 kHz                │             ┌───────────────┐
                             ├──► align ──►│ notch(60)     │──► .a - .b ──► gradient
  /1/field ──────────────────┘             │ bandpass(1,40)│                3 ch, nT
  3 ch, 500 Hz                             └───────────────┘
                                      D0 · 500 Hz · 6 ch
```

The filters become one node over six channels, not two nodes over three.
Identical coefficients are then a fact of the graph's shape rather than a
property someone has to check: the phase-matching bug that costs a gradiometer
its rejection is no longer expressible.

### What align does, and what it refuses

- **Checks epoch and session.** Inputs must share a timescale identity from the
  SYNC/timeref broadcast. Two sensors that never shared a hub have unrelated
  time, and no amount of buffering repairs it.
- **Requires matching rates.** A rate difference is an error naming the fix, not
  an implicit resample. Interpolating without being asked is how you get a
  plausible trace and a wrong number.
- **Corrects sub-sample offset once.** Devices sharing a timebase and rate can
  still be offset by a fraction of a period; a fractional-delay filter fixes it
  here and nowhere else.
- **Emits over the intersection.** Output begins when every input has data, so
  the graph lags by the slowest input's latency. `tiodsp check` prints that
  number rather than letting anyone find it in a plot.
- **Names channels by provenance.** `align(a, b)` over two 3-channel sources
  yields `a.x a.y a.z b.x b.y b.z`, which is what makes `.a - .b` a name-keyed
  operation.

### The failure that has no software fix

Unsynced sensors produce a runtime error pointing at the `align` that assumed
otherwise. `xcorr_align()`, which estimates a constant offset from a signal both
sensors see, exists as an explicit node the user must write. It is never inserted
automatically, and it is never silent.

## 6. The language

Working name TSL. The file extension is bikeshed-grade; the shape is not.

```
# gradiometer.tsl — software gradiometer from two vector magnetometers.

source a = /0/field          # 3 channels: x, y, z — 1 kHz
source b = /1/field          # 3 channels: x, y, z — 500 Hz

param line : Hz = 60        [45 .. 65]
param lo   : Hz = 1         [0.1 .. 10]
param hi   : Hz = 40        [10 .. 200]

# One domain, six channels: a.x a.y a.z b.x b.y b.z.
# Rate is matched explicitly before align; align refuses to guess.
let fr = align(a | decimate(2), b)

# One filter chain over all six channels — identical coefficients by
# construction, so the two arms cannot drift in phase.
let clean = fr | notch(line, q = 30) | bandpass(lo, hi, order = 4)

out gradient : nT = clean.a - clean.b
```

The source paths are the sensors as `tiodsp` mounted them, so `/0` and `/1` mean
in a spec exactly what they mean in the app's sidebar (§2). Each `param` becomes
a live RPC on the DSP device, and its declared range becomes the `.max` sibling
the app's slider tray already looks for (§10) — the bracket is not decoration.

Channels are matched **by name**. `clean.a - clean.b` pairs `a.x` with `b.x`,
`a.y` with `b.y`, `a.z` with `b.z`, never by position. A sensor whose columns are
ordered differently, or a stream that gained a column in a firmware revision,
produces a diagnostic instead of a quietly rotated gradient. Positional
combination is still available, but only through `mix`, where writing a matrix
makes the intent explicit.

Swapping the subtraction for a common-mode decorrelator is one line, and it is
the same line the graph editor rewrites when you drop a different node onto that
edge:

```
out gradient : nT = decorrelate(clean.a, ref = clean.b, window = 10s)
```

The error the compiler gives when you forget the rate match:

```text
error[E0412]: cannot align signals in different rate domains
  --> gradiometer.tsl:9:14
   |
 9 | let fr = align(a, b)
   |                ^     ^ 500 Hz  (from /1/field)
   |                1 kHz   (from /0/field)
   |
   = note: alignment never resamples on its own — interpolating without
           being asked would change your numbers invisibly.
   = help: match the rate first, ahead of any filtering:
             let fr = align(a | decimate(2), b)
   = note: decimating after the filters would compile, but the two arms
           would carry different coefficients and mismatched phase.
```

### Grammar sketch

```text
program     := item*
item        := source | param | binding | output | comment
source      := "source" ident "=" stream_path attr*
param       := "param" ident (":" unit)? "=" literal range?
binding     := "let" ident "=" expr
output      := "out" ident (":" unit)? "=" expr
expr        := term (("|" call) | (binop term))*
term        := ident | literal | stream_path | call | select | "(" expr ")"
select      := term "." ident                 # name-keyed channel group
call        := ident "(" arg ("," arg)* ")"
arg         := expr | ident "=" expr          # positional or named
stream_path := "/" segment ("/" segment)*     # /0/field, /1/field/x
attr        := "@" ident "(" arg* ")"         # @rate(500), @pos(120, 40)
```

### As implemented

The grammar the parser accepts is written out at the top of
`rust/tio-dsp/src/lang/parser.rs`. It settles what the sketch left open:

- **Precedence.** `*` and `/` bind tighter than `+` and `-`, and a pipe binds
  loosest, so `a - b | f()` filters the difference. A stage cannot be followed
  by an operator without parentheses.
- **Definitions come before their uses**, so a spec cannot describe a cycle.
- **Attributes carry the types offline.** Checked without a device, a source
  states its own `@rate(…)`, `@channels(…)` and `@unit(…)`. The spec above
  needs them until `--mount` exists; `examples/gradiometer.tsl` has them.
- **A path is one run of text.** Its parts touch, and a segment may contain
  dots, as `ColumnFilter` allows (`/0/vector/sync.vco.x`). Selecting from a
  path written inline takes parentheses.
- **Units follow the calcium text calculator.** A unit is a product of
  symbols, kept as written: `nT/V`, `m/s^2`. Multiplying and dividing collect
  powers, so volts times `nT/V` is `nT`, and `integrate()` gives `V*s`. SI
  prefixes are taken off against a small table of units; a symbol the table
  does not know is a unit of its own. A quantity is `10s` or `10 s`.
- **A conversion is always written.** `value in unit` is the only thing that
  changes a number for the sake of its unit, and it binds loosest of all. Two
  signals in `nT` and `µT` do not subtract until one is converted, and the
  error says `cannot convert X to Y` when they never could. Where an argument
  is a frequency or a duration, anything that converts to hertz or seconds is
  accepted, `1 / 20ms` included.

- **A function is its body written out.** `fn clean(s) = s | notch(line) |
  bandpass(lo, hi)` leaves names open, and a call fills them in: piped,
  `a | clean()`, in place, `clean(a)`, or by name. Nothing of it is left in
  the program but the nodes its body makes, once for each call. Its body
  sees what it is given and what was defined above it, and is checked where
  it is called, since until then there is nothing to check it against. `fn`
  is a keyword, and a function shares the one set of names.

The functions the checker knows are listed in `lang/builtins.rs`, and by
`tiodsp functions`. The rendered text of every error code is checked in under
`tests/diagnostics`.

## 7. Compilation and diagnostics

Source → tokens → lossless CST → AST → resolve → domain and unit check → lane
expansion (§8) → schedule. Errors at every stage are the same `Diagnostic`
struct, which is what lets one implementation serve rustc-style carets in the
CLI, log packets on the wire, and gutter markers in the editor.

```rust
pub struct Diagnostic {
    pub severity: Severity,             // Error | Warning | Note
    pub code: Option<&'static str>,     // "E0412" — stable, greppable
    pub span: Span,                     // byte range in the source text
    pub labels: Vec<(Span, String)>,    // secondary spans, e.g. each arm's rate
    pub notes: Vec<String>,
    /// Set for diagnostics raised after the graph is running. An epoch
    /// mismatch is only observable once both streams deliver data, but it
    /// still points at the `align` that assumed they were comparable.
    pub runtime: bool,
}
```

Runtime diagnostics carrying spans is the unusual part and it is worth the
plumbing. The most important failure in this system, two sensors that were never
hub-synced, cannot be detected until data arrives, and the only useful place to
report it is on the expression that assumed they were comparable.

## 8. Execution, threading, and cores

The obvious parallel design — a thread per node, connected by queues — is the
wrong one here. Latency stacks up across the pipeline, cache locality is poor,
and one heavy node throttles everything behind it. The width of a gradiometer DAG
is two. That is not where the cores are.

### Where the parallelism actually is

It is in the channels. A domain is one contiguous *(channels × frames)* matrix,
and for every filter, gain, detrend and elementwise-arithmetic node the
per-channel state is completely independent. Six channels through a five-node
chain is thirty independent pieces of work with no synchronization between them.
So each node declares its coupling, and the compiler expands the node DAG into a
**lane DAG** accordingly.

```text
  node graph
      align ──► biquad · 6 ch ──► magnitude ──► out
    (coupled)   (independent)     (coupled)

  lane graph — one task per box
                 ┌─ biquad · a.x a.y ─┐
      align ─────┼─ biquad · a.z b.x ─┼──► magnitude ──► out
    (1 task)     └─ biquad · b.y b.z ─┘     (1 task)
                    3 tasks, f64x2
```

The bundle, not the channel, is the task. A biquad is a recurrence in time and
cannot be vectorized across samples, but with the same coefficients across
channels it vectorizes perfectly across them, so a task takes a SIMD bundle (2
f64 lanes on NEON) rather than a single channel. Channel-major layout with a
fixed stride is what makes that fall out of the loop rather than requiring
intrinsics.

Coupled nodes stay whole: `align`, `magnitude`, `mix`, `decorrelate`, `psd`.
Everything else expands.

### Determinism under work stealing

Scheduling order is nondeterministic and the results must not be. Three rules
hold that line, and the third is the one that quietly breaks if nobody is
watching:

1. Every task writes a disjoint, pre-allocated output slice. No task reads
   another's partial state.
2. Dependencies come from the lane DAG, so a task cannot start before its inputs
   are complete.
3. **Every cross-lane reduction uses a fixed-shape tree.** Floating-point
   addition is not associative, so `par_iter().sum()`, whose order depends on how
   work happened to be stolen, makes the golden test flap by an ulp and then by
   more. Coupled nodes that reduce across channels must reduce in a shape fixed
   at compile time.

### Amortizing the fork-join

A tick's fork-join costs a few microseconds. A 3-channel notch over 64 samples
costs less than that, so parallel-always is slower than serial for small graphs.
Two mitigations, both cheap: coalesce blocks ahead of the graph using the
`BatchCoalescer` that already exists in `data/coalesce.rs`, so a tick covers
thousands of frames rather than tens; and have the scheduler estimate total tick
cost from measured per-node throughput and run the whole tick inline below a
threshold.

### Pool sizing and QoS

When `tiodsp` runs on a thread inside the app, its pool must not starve the
thread draining the socket or the one drawing the UI: size it
`available_parallelism() - 2`. On Apple Silicon the QoS class matters more than
the count. A pool left at default or background QoS is scheduled onto efficiency
cores and can finish *slower* than a single thread on a performance core. Set
`userInitiated`. Standalone, take everything.

### Two more axes, offline only

For `tiodsp run --log` over a long recording, independent runs in the log have no
shared state and can be processed concurrently, as can independent files. That is
where a 16-core machine actually gets used near-linearly; live acquisition is
latency-bound, not throughput-bound, and rarely needs more than a few cores.

### The rest of the execution model

- **Backpressure.** The input channel is bounded; on overflow drop the oldest
  blocks and mark a run boundary, so a slow graph degrades exactly like packet
  loss, which every layer up to the plot legend already displays honestly.
- **Panic isolation.** `catch_unwind` around the tick. A panicking node poisons
  its graph and raises a diagnostic; it does not take the device down. The bridge
  already applies this around `fetch_device`.
- **Live reload.** Each node carries a content hash over
  `(kind, params, ordered input hashes)`. On recompile, unchanged hashes keep
  their state and the rest reset, so retuning a bandpass resets it and everything
  downstream while leaving the notch ahead of it untouched. While the text is
  momentarily unparseable, the last graph that compiled keeps running behind the
  diagnostics.

## 9. The node library

Coupling is declared, because it decides the parallel decomposition.

| Node | Coupling | Notes |
|---|---|---|
| **Sources and sinks** | | |
| `/route/stream` | — | Whole stream as N named channels, or one column with a third path segment. Establishes a domain. |
| `out name` | — | Becomes a stream on the DSP device, published under `/255` (§2). |
| **Domain — always explicit, never inserted** | | |
| `align(a, b, …)` | coupled | Merges inputs into one domain and one named channel set. Errors on rate or epoch mismatch; corrects sub-sample offset once (§5). |
| `decimate(n)` | independent | Filter-then-drop; new domain at rate ÷ n. Bare downsampling is not offered — it is almost always a bug. |
| `resample(rate)` | independent | Polyphase, new domain. Reports its own passband so the anti-alias filter is not a secret. |
| `xcorr_align(ref)` | coupled | Estimates a constant offset from the data. Explicit and opt-in (§5). |
| **Filters — biquad cascade, transposed direct form II, f64** | | |
| `notch(f, q)` | independent | RBJ cookbook. `harmonics = n` builds a comb for 60/120/180 in one node. |
| `bandpass(lo, hi)` | independent | Butterworth via analog prototype + bilinear transform with frequency pre-warping. |
| `lowpass` / `highpass` | independent | Same design path. Odd orders get a real pole section. |
| `…, phase = zero` | independent | Any of the filters above, run both ways: zero phase, recordings only. Asking for it live is refused, not a surprise. This is what the `filtfilt(…)` once listed here became. |
| `detrend(mode)` | independent | mean / linear / quadratic — the modes `DetrendMethod` already defines. Over a whole run, so recordings only. |
| **Arithmetic — name-keyed** | | |
| `a - b`, `a + b` | independent | Channel names must pair. `clean.a - clean.b` matches x to x, y to y, z to z. A missing or renamed channel is a diagnostic. |
| `a * k`, `a / k` | independent | Scalar or per-channel gain. |
| `magnitude(v)` | coupled | N channels → 1. Fixed-shape reduction, per §8. |
| `mix(v, M)` | coupled | Matrix product: axis alignment, coil-frame rotation, and the escape hatch for positional combination. |
| `integrate` / `derivative` | independent | Trapezoidal and central difference, both with explicit drift and noise-gain notes. |
| **Adaptive — the common-mode family** | | |
| `decorrelate(x, ref)` | coupled | Default `method = ls`: sliding-window least squares of x on ref, subtract the fit. This is the "common mode varying in amplitude" case — a drifting scalar gain. |
| `… method = nlms` | coupled | Multi-tap adaptive filter for coupling that varies with frequency, not just amplitude. M7. |
| `… method = rls` | coupled | Faster convergence, higher cost, numerically fussier. Same node, same spec line. |
| **Spectral and statistics** | | |
| `psd(window)` | independent | The twinleaf library's `Welch`, the one the app's spectrum plots use, over the last `window` of a run. Its output is over frequency, not time. Recordings only. |
| `noise_floor(window)` | coupled | Today's `Derivation::NoiseFloor`, re-expressed as a node. |
| `rms(window)` | independent | Sliding RMS, per channel. |

**Write the filter design, don't take a dependency.** RBJ biquads and a
Butterworth prototype with bilinear pre-warping are roughly 300 testable lines.
The phase response *is* the product here, so the coefficient path is worth owning
outright rather than inheriting from a crate whose numerics you would have to
characterize anyway. It also lets the state layout be chosen for the
bundle-parallel loop of §8 rather than fought with.

## 10. The control surface

Params, the spec and diagnostics all reach the app through mechanisms the app
already has. There is no new Swift model, no new FFI command, and no bespoke
inspector.

### Params are RPCs

Every `param` in the spec becomes a readable/writable RPC on the DSP device:
`dsp.line`, `dsp.lo`, `dsp.hi`. The sidebar lists them, the RPC terminal reads
and writes them, and Favorites pins the ones you tune often — all of that works
the day the device exists.

Sliders need a range, and `RpcDto` carries type, permissions and size but not
bounds. The app already solved this with a convention: the slider tray looks for
a sibling `<name>.max` RPC and computes a fallback when there is none. So the
device publishes `dsp.line.max` alongside `dsp.line`, derived from the bracket in
the spec:

```
param line : Hz = 60   [45 .. 65]
                        │     └──► dsp.line.max
                        └────────► dsp.line.min
```

The spec stays the single source of truth for presentation — unit, range, doc —
and the RPCs are the transport. Nothing has to be configured twice.

### An RPC write splices the spec

The one coherence question this raises: if `dsp.line` is written to 55, does the
spec text change? It must, or a reload silently reverts a tuned instrument.

The device owns the spec text and its CST, so an RPC write performs exactly the
span splice §12 describes for a canvas drag — replace the literal, reparse,
recompile, carry over unchanged node state. `dsp.spec` then always reads back
live state, the editor and the slider cannot disagree, and undo is still text
undo. The mechanism the graph editor needed anyway turns out to be the mechanism
the parameter RPCs need.

### The spec is an RPC

`dsp.spec` reads and writes the source text. `MAX_PAYLOAD_SIZE` is 500 bytes, so
a spec of any real size must be chunked — and firmware upload already establishes
the pattern in this codebase: fixed-size chunks with an offset/size/crc envelope
and a bounded number in flight. `dsp.spec.size`, `dsp.spec.read(offset)` and
`dsp.spec.write(offset, bytes)` follow that shape rather than inventing another.

### Diagnostics come back as they are produced

A `dsp.spec` write replies with an accept or a diagnostic list. Runtime
diagnostics — the epoch mismatch that only appears once data flows — arrive as
TIO log packets, which the app already collects and displays in the log sidebar
and the slide-over. The editor's gutter is a filter over that same stream, keyed
by the spans the diagnostics carry.

### Provenance is automatic

The device emits its spec text as a metadata record at stream start. Any recorder
captures it — `tio log` as much as the app — so a recording explains itself
without the recorder knowing anything about DSP. HDF5 export lifts it to an
attribute.

## 11. Private modules

There is nothing left to design. A private DSP module is a TIO device.

Everything an earlier draft needed for this — a plugin wire protocol, a node
manifest format, a `dsp.lock` file, subgraph fusion to amortize per-node boundary
crossings, a provider-approval security model, an SDK crate to implement against
— exists only because that draft put the boundary in the middle of the graph.
With the boundary at the process edge and TIO across it, each of those is
answered by something that already ships:

| Was going to need | Is actually |
|---|---|
| A wire protocol | TIO. |
| A node manifest | Device metadata: streams, columns, units, rates. |
| A parameter schema | The RPC registry, plus the `.max` convention (§10). |
| A lockfile for offline typing | Nothing. The device answers for itself; there is no second compiler. |
| Subgraph fusion | Nothing. The whole graph is on one side of the boundary. |
| A plugin SDK crate | "Be a TIO device", which `twinleaf` already provides. |
| Provider approval and an endpoint allowlist | The device picker and the remembered-URL list. Connecting to a DSP server is the same user action as connecting to a sensor. |

A private module ships as a binary that speaks TIO. It can link `tio-dsp` for the
public node library and register private nodes alongside, or implement the graph
however it likes and simply publish streams — the app cannot tell and does not
care. What stays public is this repository: the language, the engine, and the
node library of §9. `docs/private-dsp-device.md` says how, and
`rust/examples/private-dsp` does it.

The security property is worth stating plainly, because the earlier design had a
hole here. A spec can no longer cause a connection: specs name streams, not
hosts, and the only thing that opens a socket is a user picking a device. A `.tsl`
file received from someone else is inert text.

In-process native plugins remain unavailable — iOS loads no third-party native
code and a Mac App Store build runs under library validation — but it no longer
costs anything, because the boundary was always going to be a process boundary
and it is now the same one the public path uses.

## 12. Text and graph, both ways

A graph editor that regenerates the file on every change destroys comments,
reorders declarations and produces unreadable diffs, which is exactly what makes
people stop trusting the visual side. So the canvas never emits a file. It emits
a *span edit*: replace bytes 412–414 with `45`. Reparse, rerender. Undo is text
undo, one history for both panes — and, per §10, an RPC write on a `param` takes
the same path.

```text
  ┌──────────────┐  parse   ┌──────────────┐  lower   ┌───────────────┐
  │ source text  │ ───────► │ CST + spans  │ ───────► │ node canvas   │
  │ on the device│          │ keeps trivia │          │ @pos if moved │
  └──────────────┘          └──────────────┘          └───────────────┘
         ▲                                                    │
         └────────────────────────────────────────────────────┘
              splice one span — never regenerate the file
```

Every canvas gesture has a textual meaning. Dragging a slider replaces a numeric
literal's span; inserting a node splices `| newnode(…)` into a pipeline; deleting
one removes that segment. Layout lives in `@pos` attributes written only when a
node is moved by hand, so files authored in the editor stay clean and files
arranged on the canvas keep their arrangement.

## 13. Rendering the graph

Publication figures go through [autograph](https://typst.app/universe/package/autograph/),
which renders with [fletcher](https://typst.app/universe/package/fletcher/) on a
layout computed by Graphviz through
[diagraph-layout](https://typst.app/universe/package/diagraph-layout/):
Graphviz-quality hierarchical layout, Typst-quality typography, and a figure that
drops straight into a paper or a lab notebook.

```typst
// gradiometer.tsl, drawn by `tiodsp graph --typst`.
#import "@preview/autograph:0.1.0": diagram, node, edge
#import "@preview/fletcher:0.5.8": shapes

#let wire = (stroke: 0.6pt + black, mark: (end: ">", fill: black, scale: 0.8))

#diagram(
  bezier: true,
  node-shape: shapes.rect,
  node-stroke: 0.6pt + black,
  node-inset: 6pt,
  node-corner-radius: 2pt,

  node(<n0>, align(center)[#raw("/0/field") \ #text(0.8em, "1 kHz · 3 ch · nT")], shape: shapes.pill),
  node(<n2>, align(center)[#raw("decimate(2)") \ #text(0.8em, "500 Hz · 3 ch · nT")]),
  node(<n3>, align(center)[#raw("align") \ #text(0.8em, "500 Hz · 6 ch · nT")]),
  node(<n4>, align(center)[#raw("notch(line, q = 30)")]),
  // …
  node(<out0>, align(center)[#strong(raw("/255/gradient")) \ #text(0.8em, "500 Hz · 3 ch · nT")], shape: shapes.pill, stroke: 1pt + black),

  edge(<n0>, <n2>, ..wire),
  edge(<n2>, <n3>, ..wire),
  edge(<n3>, <n4>, ..wire),
  // …
)
```

This is what the emitter writes, and it differs from the sketch this section
once had in the ways autograph 0.1.0 required when it was read: an edge takes
no label, so a signal is described on the node that makes it, wherever it
differs from what came in; drawn as curves, an edge takes its own stroke and
arrowhead; and the layout runs the way Graphviz runs it, top to bottom, with
nothing to turn it. Everything that came from the spec is written as a Typst
string, so that no name or unit is read as markup.

Two ways to reach a PDF, and the plan takes both:

- **Emit and shell out.** Default. Write `.typ`, run `typst compile` if it is on
  the PATH. Zero heavy dependencies, and the source is itself a useful artifact
  someone can edit.
- **Embed, behind a feature.** Typst is a Rust crate, so `--features typst`
  compiles in-process to SVG or PDF with no external toolchain. The cost is real:
  the crate is large, it needs a `World` implementation for font and package
  resolution, and `diagraph-layout` ships Graphviz as WASM that Typst runs
  through `wasmi`. Packages are found as Typst finds them, and fetched from
  Typst Universe when they are nowhere else; `--packages` names a directory
  of vendored ones to look in first (§18 says why none are vendored here).

**Not the interactive canvas.** Typst compiles a document; it does not hand back
a scene graph you can hit-test, drag, or reflow at 60 fps. The editor's canvas
stays native SwiftUI with a small layered layout — these DAGs are ten nodes, not
a thousand. Autograph is the *export* and *print* path, reachable from the File
menu that already prints plots.


## 14. The editor surface

The editor is a device settings view. It reads and writes `dsp.spec` on whichever
DSP device is connected, so it works identically for the in-app instance and for
a private server across the lab.

- **Split view.** Text on one side, node canvas on the other, in a dedicated
  window. The slide-over that hosts the TIO log and RPC terminal is too narrow
  for a split, but it is the right home for the params list during live work —
  and those are just RPC rows (§10).
- **Highlighting is local; checking is remote.** The bridge links `tio-dsp`'s
  front end — lexer, parser, spans — so syntax highlighting and syntax errors are
  instant and offline. Semantic diagnostics, which need the sensors' real rates
  and epochs, come back from the device. Same crate on both sides, so they cannot
  disagree about what the syntax is.
- **Selection is bidirectional.** Clicking a node selects its span; putting the
  caret in a pipeline highlights its node.
- **Editing is span splicing** (§12), whether it originates from the text pane,
  the canvas, or a slider.

**Learn from commit 3614991.** `DocumentWindow.body` had to be split because
Xcode 26.6 could not type-check it as one expression. A split editor with a
canvas, a text view, an inspector and a diagnostics rail is exactly the shape
that hits that wall. Decompose it into small view structs from the first commit
rather than after the build times out.

## 15. The CLI

`tiodsp` is the DSP device. Serving is its main mode, not an afterthought.

```sh
# Serve: mount sensors at /0, /1, publish graph output at /255, expose params
# as RPCs. This is what the app connects to, in-app or across the lab.
tiodsp serve gradiometer.tsl \
  --mount tcp://sensor-a.local \
  --mount serial:///dev/cu.usbmodem14201 \
  --listen tcp://127.0.0.1:0

# Parse, check domains and units, report end-to-end latency. Exit non-zero
# on error. --mount lets it check against live metadata; without it, rates
# and channel names come from the spec's own annotations.
tiodsp check gradiometer.tsl

# Publication figure via autograph (§13), or Graphviz DOT for a quick look.
# --pdf and --svg compile in process with --features typst, and otherwise
# run the `typst` on the PATH.
tiodsp graph gradiometer.tsl --typst > fig.typ
tiodsp graph gradiometer.tsl --pdf fig.pdf
tiodsp graph gradiometer.tsl --dot

# What a spec may call. A private build lists its own functions here too.
tiodsp functions

# Offline, over a recording. This is the golden-test path. --threads is a
# performance knob and never changes the numbers.
tiodsp run gradiometer.tsl --log session.tio --hdf5 gradient.h5 --threads 16
```

Once `tio-dsp` is promoted into the `twinleaf-rust` workspace this becomes
`tio dsp …` alongside `monitor`, `health` and `log`, with no change to the
engine. At that point `tio dsp serve` also subsumes `tio proxy mount`, since
mounting sensors with an empty graph is exactly what the mount already does.

## 16. Proving it correct

**Invariance under segmentation and under core count.** Run the same log through
the same graph four ways — one sample per block and 4096 per block, crossed with
one thread and sixteen — and require all four outputs to be *bit-identical*.
Every state-carry bug, every boundary-handling bug, every accidental dependence
on arrival timing, and every order-dependent floating-point reduction fails this
and almost nothing else catches them.

The topology of §2 makes this stronger than it was: the app is no longer in the
loop at all, so `tiodsp` alone is the unit under test and there is no second
implementation for the app to diverge from.

- **Golden files.** `spec + input.tio → expected.csv`, byte-compared in CI.
- **Per-node numerics.** DC gain, notch depth at f0, passband ripple, group
  delay, impulse response against scipy-generated fixtures checked into the repo.
- **Properties.** Linearity (`filter(a+b) == filter(a)+filter(b)` within
  tolerance), identity pipelines, bounded resample round-trip error.
- **An end-to-end physics test.** `tio simulate` already exists; use it to
  generate two magnetometers sharing a known common mode plus independent noise,
  then assert the decorrelator's rejection ratio against the analytic bound. That
  test fails loudly if the domain or phase-matching logic of §5 regresses.
- **A device conformance test.** Point `tio monitor` and `tio log` at a running
  `tiodsp serve` and assert they see a well-formed device: metadata, streams,
  RPCs, `rpc.info` answers. If the standard tools are happy, the app will be.
- **Diagnostic snapshots.** The rendered text of every error code, checked in.
  Error messages are the main interface to a language, and they rot silently.

## 17. Milestones

Genuinely sequential; each depends on the last.

**M0 — Workspace, signal model, invariance harness.** Split `rust/` into a
workspace; land `Block`, `Domain`, `SignalType`, the `Node` trait, lane expansion
and the rayon scheduler. Graphs are built programmatically, no language yet. Ends
with the four-way invariance test passing on a trivial graph. *Ships the
guarantee everything else rests on.*

**M1 — The language.** Lexer, lossless CST, parser, resolver, domain and unit
checking, the `Diagnostic` pipeline with rustc-style rendering and snapshot
tests. *Ships `tiodsp check`, `tiodsp graph --dot`.*

**M2 — Node library v1 and offline runs.** Sources, `align`, `decimate`,
`resample`, biquad design and cascade, name-keyed arithmetic. The gradiometer
spec runs end to end over a recording. *Ships `tiodsp run --log`.*

**M3 — The device.** `tiodsp serve`: mount sensors at `/0`…, publish outputs at
`/255`, params as RPCs with `.max` siblings, `dsp.spec` chunked read/write, spec
text as a provenance record, diagnostics as log packets. Verified with
`tio monitor` and `tio log` before the app sees it. *Ships a DSP anyone can
connect to.*

**M4 — The app connects.** Route sensors through `/0` universally, with migration
for saved documents holding root-relative keys. Host `tiodsp` on a thread in the
Rust core, serving loopback. The gradient plots, logs and exports with no new
plotting or export code. *Ships the first moment it is demonstrably useful.*

**M5 — The editor.** Split-screen text and canvas over `dsp.spec`, local
highlighting from the linked front end, remote semantic diagnostics, span-splice
editing shared with the param RPCs, live reload with content-hash state
carry-over. *Ships design in either domain, as asked for.*

**M6 — Figures and private modules.** The autograph emitter with the
embedded-Typst feature behind it. Documentation and a worked example for shipping
a private DSP device: what to link, what to publish, how to be a well-formed TIO
device. Little new code — mostly proving M3's surface is enough. *Ships one public
binary with private algorithms beside it.*

**M7 — Adaptive and ergonomic.** NLMS and RLS decorrelation, `filtfilt`, `psd`
unified onto the moved `WelchOp`, `fn` sugar. Promote `tio-dsp` upstream as
`twinleaf-dsp` and expose it as `tio dsp`. *Ships one canonical home.*

## 18. Open calls and risks

### Open — synthesis sources

Whether the language needs signal *generators* as sources: sine, chirp,
band-limited noise, a step. They cost almost nothing — a generator is a source
node with no device behind it — and they would let a spec be developed and
tested with no hardware attached, and let `tiodsp check` report a measured
transfer function rather than a designed one. The design question is whether a
generator establishes its own domain or must be pinned to an existing one.
Pinning is more useful, since the common case is injecting a test tone alongside
real data.

### The `/0` migration

Making `/0` universal changes the route of every column in every saved document,
pane selection and remembered layout. A compatibility read that maps
root-relative keys forward is straightforward, but it has to land in M4 with the
change itself, not after someone loses a layout.

### Latency of the extra hop

Sensor data now reaches the app through `tiodsp` rather than directly, even when
the graph is empty. The mount already does this for the multi-sensor case, so the
cost is known rather than speculative — but it should be measured against a
direct connection in M4 and reported, not assumed negligible. If it matters, a
short-circuit that skips the loopback socket for the in-app instance is possible
without changing any interface.

### Sub-sample offset correction is not free

`align` applies a fractional-delay filter to bring inputs onto a common grid. That
filter has its own phase response, and it is applied to one arm and not the
other, which is precisely the asymmetry a gradiometer is sensitive to. Applying
the same filter to *every* arm — a zero-delay one to the reference — keeps the
arms symmetric at the cost of a little latency. Worth deciding in M2, not
discovering in M4.

Decided in M2. When the arms' grids coincide, `align` shifts by whole samples
and changes no sample. When they do not, every arm goes through the same
centred windowed-sinc low-pass, each at its own fraction of a sample, the first
arm included. The filter is flat to 0.8 of Nyquist and 90 dB down at it, and
costs 29 samples of latency. `decimate` and `resample` use the same filter
centred on each output instant, so they delay nothing either: sample `k` of a
signal decimated by `n` is the instant of input sample `k * n`. A 50 nT common
field at 7 Hz, through one arm that is decimated and one that is not, cancels
to better than 80 dB in `tests/run.rs`.

### What M2 left out

- **Functions that check but do not run.** `detrend`, `decorrelate`, `rms`,
  `integrate` and `derivative` have signatures and no kernels. Running a spec
  that calls one is refused at that call.
- **Only CSV.** `tiodsp run` writes `--csv`. The library's HDF5 writer takes
  its own batch type, which a graph's output is not.
- **A gap resets what it feeds, in recording order.** A lost packet on one arm
  resets the `align` and drops what the other arms were holding for it. Which
  samples those are follows the order of packets in the recording, so the
  output is the same at any block size and thread count, but it is a few tens
  of samples shorter around each gap than the data would allow.
- **Nothing bounds an `align` buffer.** An arm that stops while another runs on
  is held without limit. §8's bounded input with drop-oldest is M3's.
- **One rate per stream per recording.** A stream that changes rate partway is
  refused rather than split into runs with their own domains.
- **Params are fixed for a run.** `--set` gives them values at the start.
  A served spec can be retuned, as below.

`tiodsp check` has since been taught to print each output's latency: what the
graph's `decimate` and `resample` stages make it wait, and what more an `align`
would if its arms turned out to sample at different instants.

### How M3 was built, and what it left out

`tiodsp serve <spec> --mount <url>…` hosts the twinleaf proxy with the sensors
mounted at `/0`, `/1`, … and a device of its own at `/255`. That device is
answered for in `serve.rs`: it sends heartbeats, describes its streams the way
a sensor does (the reply to `dev.metadata` is built by `twinleaf-device`'s own
function), and lists its RPCs. Checked against the installed `tio` 2.4.0 and
`tio simulate`: `tio rpc list` shows the params with their types, reads and
writes work and refuse what they should, and a recording made by `tio log`,
run back through `tiodsp run`, shows the published output equal to what it
should be at every timestamp.

- **The device is over loopback, not in process.** The proxy has no public way
  to mount a device that lives in its own process, so `/255` listens on a
  loopback TCP port and the proxy mounts it by URL. The samples to compute
  from are read back through the proxy as a client would read them. A sample
  crosses loopback twice inside the process on its way to an output, which is
  the latency §18 said to measure. Measured on an M-series Mac, release
  build, with a spec that adds none of its own: an output reaches a client
  0.07 ms after the sample it was computed from at the median, 0.10 ms at the
  95th percentile and 0.25 ms at most, over 1,200 samples at 200 Hz
  (`tests/server.rs`, the ignored test).
- **A retune restarted the graph.** `dsp.<param>` rewrites the param's literal
  in the spec, checks the text and runs what that gives, as §10 asks, so
  `dsp.spec` always reads back what is running. In M3 every stage then started
  over from rest. M5 carries over the state of what did not change; see below.
- **The spec is a param's only home.** There is no `--set` when serving.
- **`dsp.spec` is four RPCs.** `dsp.spec.size`; `dsp.spec.read` with an offset;
  `dsp.spec.write` with an offset and text, which must follow the last write,
  and with no argument says how much is held; and `dsp.spec.apply`, which
  takes the text if it checks. A text that does not check is refused, and its
  diagnostics go out as log packets, rendered as the CLI prints them.
- **Provenance is log packets.** There is no metadata record to put a spec's
  text in, so the device says what it is running in its log when a client
  connects and when the spec changes. A recorder that keeps log packets keeps
  it.
- **Ranges have both ends.** A param with a range gets `dsp.<name>.min` beside
  `dsp.<name>.max`, the sibling the app's slider tray looks for.
- **Sensors on different clocks are not merged.** Each of `tio simulate`'s
  devices names itself as its time reference, so an `align` across two of
  them is refused, as §5 says it must be. There is still no `xcorr_align`.
- **Not checked.** `tio monitor`, which wants a terminal this was not run in.
  The app itself, which is M4. A sensor that goes away and comes back. More
  than one client at a time. `tests/server.rs` runs the whole path over real
  sockets with a sensor of its own making: mount, serve, read the outputs,
  set a param, read the spec back, stop.
- **Still unbounded.** An arm of an `align` that stops is held without limit,
  as in M2.

### How M4 was built, and what it left out

- **Every session mounts its sensor at `/0`.** The bridge opens a layout for
  one URL as it did for several (`spawn_connect` in `tio-bridge`). The one
  exception is a TCP URL on this machine, which names a proxy, such as
  `tiodsp serve`, whose tree is already laid out and is opened as it is.
- **A proxy on another machine is not told apart from a sensor.** It is
  mounted at `/0` like one, so its own `/0` and `/255` land a level down.
  Connecting the app to a signal graph running on another host therefore does
  not work yet, though §2 draws it.
- **In the app the graph's device is mounted on the app's proxy.** §2 draws
  `tiodsp` as a listener the app connects to. Hosting a second proxy for it
  meant two proxies opening one sensor, and a session with a graph could not
  start until the session without one had let go of the port. So
  `tio_dsp::serve::Hosted` is only the `/255` device, on a loopback port, and
  the bridge mounts it beside the sensors in the layout it was opening
  anyway. Each sensor is opened once, and adding or removing a graph
  reconnects in a few hundredths of a second. `Server`, behind `tiodsp
  serve`, is the same device with a proxy of its own.
- **The app is given a spec from the Device menu.** Open Signal Graph… reads a
  `.tsl` or text file for the document window; Remove Signal Graph takes it
  away. The session in progress starts over with it, unless a recording has
  begun, in which case it waits for the next connection so the recording is
  not restarted. The outputs then appear as a `tiodsp` device with its
  streams to plot and its params to set, with no new plotting, logging or
  export code. The choice lasts as long as the window; it is not saved.
- **Little saved state carried a route.** Saved plot layouts are keyed by
  device name, not route, and documents are bare recordings. What did carry
  one is matched as it was written and as it is now mounted, and nothing is
  rewritten: a favorite scoped to `/` or a hub's `/1` also matches `/0` and
  `/0/1`, and a device with no name, once keyed by its URL, still finds its
  layout.
- **Old recordings keep their routes.** A log made before this plays back
  with its sensor at `/`, and one made now with it at `/0`.
- **Shared sessions change topic.** A lone sensor's Labcast topic was named
  for the root and is now named for `/0`. Whether a viewer on an older
  version follows it was not tried.
- **Checked without the interface.** The app's own bridge library was driven
  through the C entry points the app uses, with the connect command the app
  now sends: a session without a spec has its sensor at `/0`, one with a spec
  has the `tiodsp` device at `/255` with its stream and RPCs, and a spec that
  does not check comes back as the diagnostics it would print. The app builds
  for macOS and the iOS simulator. Nobody has yet opened the menu, picked a
  file and watched an output plot.

### How M5 was built, and what it left out

- **A change restarts only what it changes.** Every stage has a fingerprint
  of what it computes, and every step of a graph one of its stage, of what
  feeds it and of the channels it is called by; a source's is its name and
  its domain. When a text replaces another, `Graph::adopt` hands each step of
  the new graph the kernels, run and place of the step of the old one with
  the same fingerprint, and the rest start over with whatever they feed.
  Sources keep their cursors, so no sample is let go while the graph is
  rebuilt, and the publisher keeps the segment of a stream that did not
  change. Setting the gain after a low-pass, over RPC and mid-stream, leaves
  every later sample exactly the gain times what an undisturbed run computes;
  setting the filter's own edge starts it from rest (`tests/reload.rs`). A
  step that starts over numbers its run after every run the old graph made.
  The fingerprint is a hash in memory and is not kept across processes.
- **The front end tells an editor what it needs in one call.**
  `lang::outline` reads a text and returns how to colour it, what is wrong
  with it, the graph it describes, and where each node is written: all of the
  text that makes it, the part that is its own, the stretch to delete to take
  a piped stage out, and the offset where one may be piped on, with the
  stages that suit a signal at that rate already written. Offsets count
  UTF-16 code units, as a text view does. The bridge hands it to the app as
  JSON through `twinleaf_spec_outline`, which needs no runtime and no device,
  so colouring and checking are instant and the same crate does them as the
  graph that will run the text.
- **Every gesture is a splice.** Dragging a param replaces its digits; Remove
  deletes ` | stage(…)`; Add Stage inserts one. The edit goes through the
  text view, so it lands in the same undo history as typing, and the graph
  is then drawn from the text again. Nothing is written back from the
  canvas, and `tests/outline.rs` checks that each splice offered leaves a
  text that parses. A stage is offered only where a pipe can go without
  parentheses; inserting or deleting a node anywhere else is done in the
  text.
- **The spec moves in pieces, on the session's own connection.**
  `tio_dsp::client` is the other end of `dsp.spec`: it reads the size and
  then the text, starting over if the text changed under it, and writes in
  448-byte pieces and applies. The bridge's `transferSpec` command runs it on
  a thread and answers like a raw RPC. Against the simulator a read took
  0.5 ms and a 1.7 kB write 1.1 ms, so the editor puts the whole text to the
  graph at every change rather than patching it: a slider drag is a dozen
  texts a second, each restarting only the filter it tunes.
- **Checking is local and the graph has the last word.** A text that does not
  check here is not sent. One that does is, and what the graph then says is
  shown beside the local problems, from its log: log messages now carry
  their level to the app, and the editor shows the graph's warnings and
  errors and none of its routine notes. A source declared at 250 Hz over a
  500 Hz stream checks, is taken, and comes back as `E0501` with its place.
- **The editor is a window of the document.** Edit Signal Graph… in the Device
  menu, and in the document menu on iPad, opens it for the document's
  session: a window of its own where the platform has windows, so the plots
  stay in view, and a sheet where it has not. With no graph running it starts
  from the session's first stream, and Run starts the graph by reconnecting
  with the text, as M4's menu does; from then on changes go to the running
  graph with no reconnection. A param set from the main window's sliders
  rewrites the same text, and the editor is written to read it back when it
  has no edits of its own to lose; that path was not tried.
- **The canvas draws the last text that checked.** While a call is half
  typed the text has errors and describes no graph. The canvas then keeps
  the graph of the last text that did, dimmed and not to be acted on, since
  its places in the text are no longer the text's.
- **Layout is computed, and `@pos` is not written.** Columns by distance from
  the sources, each node level with what feeds it, scaled down to fit the
  pane. §12 keeps a node where it was dragged by writing `@pos`; nodes cannot
  be dragged yet, and the attribute is still read only on a source and
  ignored. Wires cannot be drawn by hand either: joining two signals is
  written.
- **Not done.** Line numbers and completion in the text view. A graph too
  wide for the pane scrolls rather than zooms. The editor does not save the
  spec with the document: Save As… writes a file, and the text is otherwise
  kept only as long as the window, as M4 left it. A spec edited while a
  remote `tiodsp` is the session's device is untried, for the reason M4
  gives: such a device is not yet mounted where the app looks for it.
- **How it was checked.** The engine, front end and transfer are tested in
  `rust/tio-dsp` and through the bridge binary against `tio simulate`. The
  editor was driven by hand in the iPad simulator against the same simulated
  sensor: starting a graph from the starter text, selecting a node from
  either side, dragging a param, typing a text with an error and then a
  whole new one, adding and removing a stage, and a text the sensor
  contradicts. Undoing a canvas edit was not tried, nor the badge that says
  the graph reports a problem, which was added after the last run. It builds
  for macOS, where it has not been driven, and was not tried on visionOS or
  at phone width.

### How M6 was built, and what it left out

- **The figure is written for autograph as it is, not as §13 guessed.** The
  package was read before the emitter was written: 0.1.0, over fletcher 0.5.8
  and diagraph-layout 0.0.1. `lang::typst::figure` writes the imports and one
  diagram and sets nothing about the page, so it can be included in a paper;
  `document` wraps it in a page cut to the figure, which is what `--pdf` and
  `--svg` compile. `tests/figure.rs` holds the text to what autograph reads,
  and, with the feature, has Typst compile it, names full of markup included.
- **Typst is embedded behind `--features typst`.** `figure::render` is a
  `World` of one file over `typst-kit`'s fonts and packages: 0.15 of the
  compiler, its built-in fonts, no date. Without the feature it runs the
  `typst` on the PATH and says what to do if there is none. The feature
  doubles the lockfile, from 208 packages to 433, and is in no build of the
  app: the bridge's dependency tree has none of it.
- **Packages are fetched, not vendored.** §13 asked for them vendored. The
  figure pulls five: autograph, fletcher, diagraph-layout and oxifmt under
  MIT, and cetz under the LGPL, 2.3 MB together with Graphviz as WASM. Taking
  an LGPL package into this repository is a licensing call and was not made
  here. So the first figure on a machine fetches them from Typst Universe
  into the user's Typst package cache, as `typst compile` would, and
  `--packages <dir>` looks in a directory first for anyone who vendors them.
  The compile tests are not run by default for the same reason.
- **Figures run top to bottom.** That is Graphviz's direction and autograph
  passes none of its own. A signal graph would read better left to right;
  drawing with fletcher over diagraph-layout directly would allow it.
- **The app does not export figures yet.** §13 puts export in the File menu
  beside printing. The emitter is in the crate the bridge links, so the menu
  item is a small step, but it was not taken: only the command line draws.
- **A private build is `tiodsp` with a larger library.** `Library` holds the
  public functions and whatever is added with `with`: how a function is
  written and typed, which the checker reads, and what makes its node from a
  call. A program carries the library it was checked against, so lowering,
  a session's re-check and the device's `dsp.spec.apply` all use the same
  one. The command line moved into the crate as `cli::run(library)`, so a
  private binary's `main` is one line and everything a user of `tiodsp` knows
  holds for it under its own name, `dev.name` included.
- **Only some functions can be added.** One signal in, the same rate out,
  typed by `Same`, `Magnitude`, `Integrates` or `Differentiates`. The rules
  that change the rate or join signals read the public functions' own
  arguments, and are refused for others rather than half-supported.
- **A text that cannot be built is now refused.** A private function can
  object to its arguments when its node is made, which the checker cannot
  foresee. Such a text used to be taken and then stall the graph. A session
  now builds the new graph over the streams the old one reads before it lets
  go of the old one, and hands the text back with the reason, at the call,
  if it cannot (`tests/reload.rs`).
- **The editor takes a function it does not know on trust.** The app checks
  with the public functions only. `lang::outline` therefore reads with a
  trusting library: an unknown function handed a signal is drawn as passing
  it on, and remarked on rather than refused, with the nearest known name if
  it looks like a slip. The text is sent, and the device has the last word.
  Read strictly, as `tiodsp check` and every device read, the same call is
  still `E0203`.
- **The worked example is a Hampel filter.** `labdsp`, in
  `rust/examples/private-dsp`, adds `despike(n = 5, limit = 3)`. Its tests
  hold the kernel to an independently written filter, sample for sample and
  for any block size. Served over the simulated sensor it was read with
  `tio`, connected to from the app in the iPad simulator, and edited there:
  the app drew `despike` on trust, dragging the param it follows set it on
  the device, and an even window came back refused with the function's own
  reason.
- **The spec is readable by anyone who can connect.** A private device keeps
  its algorithms, and shows its wiring. There is no switch for that.
- **A private device on another machine is still out of the app's reach**,
  for the reason M4 gives. `tio` and other clients reach it.

### How M7 was built, and what it left out

- **Every function in the table runs.** `integrate` is the trapezoid rule
  with its sum compensated, `derivative` the central difference, one sample
  late, and `rms` a sliding window whose sum is taken afresh each time its
  ring comes round. `tests/functions.rs` holds each to numpy, from its
  definition, and to the same output for any block size.
- **`decorrelate` fits each channel to all of the reference's.** Not x to x
  and y to y: every channel of the signal is regressed on every channel of
  the reference, so a sensor turned a little against its neighbour is fitted
  too. `taps` adds earlier samples of each, for coupling that differs with
  frequency. None of the methods fits an offset.
  - `ls` solves the last `window` afresh at every sample, from sums it
    keeps running and retakes each time the ring comes round.
  - `rls` is the same fit with a memory that fades over `window`. It starts
    out sure of nothing on the scale of the first sample that says
    anything, so units do not matter, and keeps its inverse symmetric.
  - `nlms` steps along the error, normalized by the regressors' power: the
    present sample's, or the window's average where that is more, because
    with few regressors a sample where the reference crosses zero would
    otherwise throw the weights. Its weights decay over one to two windows.
- **The rejection bound holds.** With a reference that sees the shared field
  in noise of its own, the best any gain can do leaves the signal's noise
  and `g² c² n² / (c² + n²)`. Least squares and RLS sit within 3 % of that
  and NLMS within 5 %, once settled. Over a recording, in §6's spec with the
  subtraction swapped out, least squares and RLS take a 50 nT field down by
  more than 40 dB and keep a 3 nT source only one sensor saw. NLMS is held
  to 10 dB there: the reference's three axes say nearly the same thing, and
  it is slow along every direction in which they barely differ.
- **A run can be closed.** `Graph::close` ends every source's run, and an
  `Extent` says so. A stage that needs the whole of a run emits nothing
  until then and all of it at once. A recording is closed at its end, and at
  a gap in any source when some stage needs whole runs, so that what came
  before the gap is emitted and not dropped. A live graph is never closed.
- **Zero phase is an argument, not a function.** `lowpass(10 Hz, phase =
  zero)`, and likewise on `highpass`, `bandpass` and `notch`, where §9 had a
  `filtfilt(…)`. The filter keeps its own arguments and its own diagnostics
  that way, and there is one fewer thing to learn. It runs the cascade both
  ways with the ends handled as `scipy.signal.sosfiltfilt` handles them, and
  matches it to a part in 10⁹ (`tests/whole.rs`), as `detrend` matches
  `scipy.signal.detrend` and `polyfit`.
- **What needs a whole run is refused live**, by `E0502`, at the call: a
  session, the device and the app all go through it. `tiodsp check` does not
  refuse it, since it cannot know which the spec is for, and the editor does
  not offer these as stages.
- **`psd` computes nothing of its own.** It hands the last `window` of a run
  to `twinleaf::data::ops::Welch` and squares what comes back, so a spectrum
  from a graph and one on a plot cannot differ. The layout of the bins is
  asked of the estimate too, with a probe, and not copied from its
  arithmetic. The plan had the estimator moving into this crate; it had
  already moved into the library, which is the better home, so this crate
  takes the library's `processing` feature instead.
- **A spectrum is a signal over frequency.** Its samples are bins, its
  domain's rate is bins per hertz and its origin the first bin, so the same
  blocks carry it, and its channels are in the unit squared per hertz. The
  checker knows it is not time: a filter applied to one is refused, the
  summary says `1023 bins of 0.48828125 Hz`, and the CSV has `bin,frequency`
  where a signal has `sample,time`. It is held to what a power spectral
  density must be: white noise at its level with its variance under the
  curve, a tone at its frequency with half its amplitude squared.
- **A window that fixes a shape is written out.** `psd(window)` takes a
  duration that is not a param, as `resample` takes a rate that is not.
- **`fn` is in the checker and nowhere else.** A call swaps the scope for
  the one the function was defined in, binds what it was given, and checks
  the body in place. What goes wrong in a body is reported there, with the
  call it went wrong for. Nodes made by two calls are written in the one
  place, so the editor's edit at either is an edit of the function.
- **A function is not checked until it is called.** A body that could never
  check goes unreported, and the function is reported as unused instead.
- **`tio-dsp` has not been moved upstream.** Promoting it into
  `twinleaf-rust` as `twinleaf-dsp`, and exposing it as `tio dsp`, changes
  another repository and was left for its owner to start. The crate still
  names no app type in its public interface, which is what the move needs.
- **Not done.** `mix`, `xcorr_align` and `noise_floor` from §9 have no
  signature yet. A spectrum cannot be served, so the app does not plot one
  from a graph; it draws the spectrum of any stream itself. Stages with
  look-ahead still lose their last samples when a run is closed. `detrend`
  has no window, and so no live form.

### Graph retention is not the display window

A graph with a 10 s align window and a 100 s decorrelator window needs retention
sized from the compiled graph's declared windows, independent of whatever a plot
happens to be showing. Straightforward to do, subtle and intermittent to debug if
forgotten.

### Parser maintenance is a standing cost

A hand-rolled lossless parser is roughly 600 lines and never quite finished:
every language addition touches lexer, CST, AST and the editor's span logic. It
is the right call — the round trip requires it, and no crate gives it for free at
this scale — but budget it as ongoing rather than one-time.

### A dependency win, taken with the 2.0 port

The bridge used to depend on `twinleaf-tools` solely for `WelchOp`, which pulled
the tools' entire CLI and TUI dependency stack (ratatui, clap, indicatif,
dialoguer) into the app build. The twinleaf 2.0 library now ships that spectral
code behind its `processing` feature, so the bridge depends on the library alone.
