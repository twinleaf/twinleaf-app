//! A private DSP device, worked through.
//!
//! This crate is the whole of what a lab writes to put an algorithm of its
//! own in a signal graph: one function, in [`despike`]. It links `tio-dsp`
//! for everything else and ships as its own binary, `labdsp`, which is a TIO
//! device. The Twinleaf app connects to it as it connects to a sensor, plots
//! its outputs, sets its params and edits its spec, and never learns what
//! `despike` does. See `docs/private-dsp-device.md`.

pub mod despike;

use tio_dsp::Library;

/// The public functions, and this lab's.
pub fn library() -> Library {
    Library::standard()
        // What the command line calls itself, and the device's `dev.name`.
        .named("labdsp")
        .with(despike::FUNCTION, despike::build)
        .expect("`despike` is not a public function's name")
}
