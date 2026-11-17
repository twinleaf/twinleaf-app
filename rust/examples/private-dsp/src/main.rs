//! `labdsp`: everything `tio dsp` does, with this lab's functions beside the
//! public ones.
//!
//! ```sh
//! labdsp functions
//! labdsp check lab.tsl
//! labdsp serve lab.tsl --mount tcp://sensor.local
//! ```

use std::process::ExitCode;

fn main() -> ExitCode {
    twinleaf_dsp::cli::run(labdsp::library())
}
