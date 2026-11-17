//! `tiodsp`: the command line of `tio_dsp::cli`, with the public functions.

use std::process::ExitCode;
use tio_dsp::Library;

fn main() -> ExitCode {
    tio_dsp::cli::run(Library::standard())
}
