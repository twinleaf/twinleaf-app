# Signal graph architecture

A text-specified DSP flow graph that turns raw sensor columns into synthesized
streams. The graph runs in a process that is, to everything else, an ordinary
TIO device: it mounts the sensors, publishes its own results alongside them, and
exposes its parameters as RPCs. Whether it runs inside the app or on another
machine is a URL.

Status: plan. Nothing here is implemented yet. Written 10 September 2026.

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
| `WelchOp` | `twinleaf-tools/src/tui/spectral.rs` | A working `ColumnOp` for Welch ASD. Moving it into `tio-dsp` also drops the bridge's `twinleaf-tools` dependency, which today exists only for this one type. |
| **Multi-sensor mount** | `tio-bridge/src/main.rs:3108` | Binds a loopback TCP port and serves several sensors as one device tree, sensor *k* at `/k`. `tiodsp` **is** this, extended. See §2. |
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

Deferred to M7, deliberately: `fn` / lambda sugar so a shared chain is written
once. It is pure compile-time substitution and adds nothing the engine can see,
and with domains the case that most wanted it — two arms, same filters — is now
one node over six channels anyway.

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
| `filtfilt(…)` | independent | Zero phase, offline only. Asking for it in live mode is a compile error, not a surprise. |
| `detrend(mode)` | independent | mean / linear / quadratic — the modes `DetrendMethod` already defines. |
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
| `psd(window)` | coupled | The existing `WelchOp`, moved into this crate so every consumer shares one implementation. |
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
node library of §9.

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
// tiodsp graph gradiometer.tsl --typst
#import "@preview/autograph:0.1.0": diagram, node, edge

#diagram(
  bezier: true,

  node(<src_a>, [`/0/field`\ #text(0.8em)[3 ch · 1 kHz]]),
  node(<dec>,   [`decimate(2)`]),
  node(<src_b>, [`/1/field`\ #text(0.8em)[3 ch · 500 Hz]]),
  node(<algn>,  [`align`], stroke: 0.8pt + rgb("#0E6E7D")),
  node(<filt>,  [`notch(60)`\ `bandpass(1, 40)`]),
  node(<sub>,   [`.a - .b`]),
  node(<out>,   [*/255/gradient*\ #text(0.8em)[3 ch · nT]]),

  edge(<src_a>, <dec>),
  edge(<dec>,   <algn>),
  edge(<src_b>, <algn>),
  edge(<algn>,  <filt>, [D0 · 500 Hz · 6 ch]),
  edge(<filt>,  <sub>),
  edge(<sub>,   <out>),
)
```

Two ways to reach a PDF, and the plan takes both:

- **Emit and shell out.** Default. Write `.typ`, run `typst compile` if it is on
  the PATH. Zero heavy dependencies, and the source is itself a useful artifact
  someone can edit.
- **Embed, behind a feature.** Typst is a Rust crate, so `--features typst`
  compiles in-process to SVG or PDF with no external toolchain. The cost is real:
  the crate is large, it needs a `World` implementation for font and package
  resolution, and `diagraph-layout` ships Graphviz as WASM that Typst runs
  through `wasmi`. Packages must be vendored rather than fetched.

**Not the interactive canvas.** Typst compiles a document; it does not hand back
a scene graph you can hit-test, drag, or reflow at 60 fps. The editor's canvas
stays native SwiftUI with a small layered layout — these DAGs are ten nodes, not
a thousand. Autograph is the *export* and *print* path, reachable from the File
menu that already prints plots.

The exact fletcher parameter spelling above, particularly whether an edge label
is positional or named, should be checked against the pinned autograph version
before the emitter is written.

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
tiodsp graph gradiometer.tsl --typst > fig.typ
tiodsp graph gradiometer.tsl --pdf fig.pdf      # --features typst
tiodsp graph gradiometer.tsl --dot

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

### A dependency win worth taking in M7

The bridge depends on `twinleaf-tools` solely for `WelchOp`, and that pulls the
tools' entire CLI and TUI dependency stack (ratatui, clap, indicatif, dialoguer)
into the app build. Moving spectral code into `tio-dsp` removes it. Adding
embedded Typst in M6 gives some of that budget back, so the two are worth landing
near each other.
