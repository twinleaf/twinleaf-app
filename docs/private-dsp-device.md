# Shipping a private DSP device

A signal graph is a TIO device (`docs/signal-graph.md`, §11). So is a private
one. An algorithm you would rather not publish goes in a binary of your own;
what leaves that binary is streams, settings and log messages, which the
Twinleaf app and the `tio` tools already know how to read. Nothing private is
ever loaded into the app.

There are two ways to build such a device. Most labs want the first.

| | You write | You get |
|---|---|---|
| **Add functions to the public graph** | The algorithm, as one or more functions | The language, checker, engine, device, command line and editor support, unchanged |
| **Be a TIO device of your own** | Everything | Plotting, logging, export and settings in the app |

A worked example of the first is in `rust/examples/private-dsp`. It builds
`labdsp`, which is `tiodsp` with one more function, `despike`. The rest of
this page follows it.

## What to link

One crate:

```toml
[dependencies]
tio-dsp = { path = "…/rust/tio-dsp" }
```

`tio-dsp` is Apache-2.0. Your crate links it and is not part of it: nothing
of yours needs to be in this repository, and nothing here needs changing.

## What to write

A function has two halves, and you give both.

**How it is written and typed** is a `Builtin`: its name, its arguments and
the rule its result is typed by. The checker reads this and nothing else, so
a spec that calls your function gets the same diagnostics as one that calls a
public one.

```rust
pub const FUNCTION: Builtin = Builtin {
    name: "despike",
    usage: "despike(n = 5, limit = 3)",
    signals: Signals::One,
    named_signal: None,
    args: &[
        optional("n", ArgKind::Integer { min: 3 }),
        optional("limit", ArgKind::Number),
    ],
    rule: Rule::Same,
};
```

The kind of an argument decides what a spec may write for it:

| Kind | A spec writes | May follow a `param` |
|---|---|---|
| `Frequency` | `60 Hz`, `1 / 20 ms` | yes |
| `Time` | `10 s` | yes |
| `Number` | `3` | yes |
| `Rate` | `500 Hz` | no: it fixes the graph's shape |
| `Span` | `2 s` | no, for the same reason |
| `Integer { min }` | `7` | no, for the same reason |
| `Choice(&[…])` | one of the words | no |

The rule says what comes out, given what went in: `Same` for a filter,
`Magnitude` for one channel in the shared unit, `Integrates` and
`Differentiates` for a unit times or per second. Those four are the ones open
to you. A function you add takes one signal and keeps its rate; one that
changes the rate, joins several signals, or types its result some other way
cannot be added yet, and `Library::with` says so rather than accept it.

**What computes it** is a `Node`, made from one call by a function you also
give:

```rust
pub fn build(call: &Call<'_>) -> Result<Box<dyn Node>, String> {
    let window = call.whole("n").unwrap_or(5);
    if window % 2 == 0 {
        return Err(format!("the window is {window} samples, and a median wants an odd number"));
    }
    Ok(Box::new(Despike { window: window as usize, limit: call.number("limit").unwrap_or(3.0) }))
}
```

`call.number`, `call.whole` and `call.choice` read arguments by the names you
declared, however the spec wrote them. An argument that follows a param reads
as the param stands now. `call.rate()` and `call.input()` give the rate,
channels and units of the signal the function is handed. What you return in
`Err` is reported at the call in the spec, as `E0501`, and a text that fails
this way is refused while the one that was running carries on.

The node itself is three small types: the node as written, the stage it
becomes once it knows its input, and the kernel that holds state and runs the
inner loop. `despike.rs` is the model, and four things about it matter:

- **The stage's output type must be what the rule promised.** The graph
  checks, and a call whose node disagrees does not build.
- **A kernel's output must not depend on how samples are cut into blocks.**
  The engine promises bit-identical output for any block size and any number
  of threads, and it can only keep that promise if every kernel does. Make
  the state after a sample a function of the samples so far.
- **`reset` forgets everything.** It is called at a new run: after a gap in
  the sensor's samples, or when the stage starts over.
- **`fingerprint` covers everything the stage computes from.** When a spec is
  changed while it runs, a stage whose fingerprint and whose inputs' are
  unchanged keeps its kernels, and the rest start over. Leave a parameter out
  and a retune will keep running the old value.

`Coupling::Independent` lets the engine run a stage's channels on different
cores. Use `Coupled` if they look at one another.

## What to ship

A `main` of one line, and the binary it builds:

```rust
pub fn library() -> Library {
    Library::standard()
        .named("labdsp")
        .with(despike::FUNCTION, despike::build)
        .expect("`despike` is not a public function's name")
}

fn main() -> ExitCode {
    tio_dsp::cli::run(library())
}
```

A name that is already a function's is refused, so a private function cannot
quietly stand in for a public one. The name given to the library is what the
command line calls itself and what the device answers to `dev.name`.

The binary is then `tiodsp` under another name:

```sh
labdsp functions                      # the public functions, and yours
labdsp check lab.tsl                  # exit non-zero on error
labdsp run lab.tsl --log session.tio  # offline, over a recording
labdsp graph lab.tsl --typst          # the figure; --pdf with Typst
labdsp serve lab.tsl --mount tcp://sensor.local --port 7900
```

## What it publishes

`serve` mounts the sensors at `/0`, `/1`, … and puts the graph beside them at
`/255`. This is everything that device says, and so everything a client can
learn about what is inside:

| | |
|---|---|
| Identity | `dev.name` is the library's name. |
| Streams | One per `out`, named for it, with its channels as columns, their units, and its rate. Timed on the sensors' own clock, so an output lays over what it came from. |
| Settings | `dsp.<param>` for each `param`, read and write, with read-only `dsp.<param>.min` and `.max` where the spec gave a range. |
| The spec | `dsp.spec.size`, `.read`, `.write` and `.apply`: the text that is running. |
| Log | A note for each text taken and each param set, and warnings and errors, with their place in the spec, for a text refused or a sensor that is not what the spec says. |

**The spec is readable.** Anyone who can connect can read the text, and so
the names of your functions, how they are wired and what they are given. The
algorithm behind a name stays in the binary. If the wiring is itself
private, there is no switch for that yet: build a device of your own, below.

A spec names streams and never hosts, so a spec cannot make the device open
a connection. The only things it reads are the sensors it was started with.

## How the app sees it

Connect to it as to a sensor: Connect to Device, then its URL, such as
`tcp://127.0.0.1:7900`. The sensors and the graph appear as devices of one
tree. Outputs plot, log and export like sensor streams, and params are
settings with sliders.

Edit Signal Graph opens the device's own text. The app checks what you type
with the public functions only, so a call of `despike` is not one it can
check. It draws the call as a stage that passes its input on, remarks that
the function is not known here, and sends the text all the same. Your device
checks it with its own library and has the last word: what it refuses, and
why, comes back in the editor's problem list.

Two limits, as things stand:

- **Same machine only.** The app opens a device tree as it is laid out only
  for a TCP URL on this machine. A graph served from another host is mounted
  like a sensor, one level down, and its sources are then not where its spec
  says. `tio` and other clients are not limited this way.
- **Typing past a private stage is a guess.** The app assumes it changes
  nothing about the signal. If yours changes the rate or the channels, what
  the editor draws after it is wrong until the device answers.

## A device of your own

If you would rather not use the graph at all, publish streams yourself. The
app cannot tell and does not need to. A well-formed device:

- answers `dev.name`, and the `rpc.listinfo` and `rpc.info` listing, so that
  its settings can be found;
- describes each stream in metadata before sending its samples: name,
  columns, units, rate, epoch and time reference;
- numbers samples so that a gap is a jump in the number;
- sends a heartbeat when it has nothing else to say;
- gives a ranged setting `.min` and `.max` siblings, which is what makes it
  a slider;
- says what is wrong in log messages, at warning or error level.

`twinleaf-device`, in `twinleaf-rust`, is the device side of the protocol.
From this crate, `tio_dsp::publish::Publisher` turns blocks of samples you
computed into a device's metadata and sample packets, and
`tio_dsp::serve::Hosted` is a whole device on a loopback port, if you want
those halves without the language.

Without `dsp.spec.size` the app offers no editor for the device, which is
right: there is no text to edit.

## Before you ship

- `cargo test` in your crate, with tests like `tests/device.rs` in the
  example: the checker knows the function, an independent calculation agrees
  with the kernel sample for sample, block size changes nothing, and the
  device takes a text that calls it.
- `yourdsp check` on every spec you ship with it.
- `yourdsp serve`, then `tio rpc list -r <url> -s /255` and a look in the
  app.
