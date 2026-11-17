//! `despike(n = 5, limit = 3)`: a Hampel filter.
//!
//! A sample is compared with the median of the last `n` samples, itself
//! included. If it lies further from that median than `limit` robust
//! standard deviations it is taken for a spike and replaced by the median;
//! otherwise it passes untouched and undelayed. The deviation is estimated
//! from the median absolute deviation of the same window, scaled by 1.4826
//! so that it reads as a standard deviation for Gaussian noise.
//!
//! It stands in here for an algorithm a lab would rather not publish. What
//! makes it private is only where it is compiled: nothing below is special.

use tio_dsp::lang::builtins::{optional, ArgKind, Builtin, Rule, Signals};
use tio_dsp::lower::Call;
use tio_dsp::node::{arity, fingerprint, Coupling, Inputs, Kernel, Node, Stage};
use tio_dsp::signal::{Domains, SignalType, Span};
use tio_dsp::BuildError;

/// How a spec writes the function, and how its result is typed.
pub const FUNCTION: Builtin = Builtin {
    name: "despike",
    // Shown in `labdsp functions` and in the checker's help.
    usage: "despike(n = 5, limit = 3)",
    // One signal, usually piped in.
    signals: Signals::One,
    named_signal: None,
    args: &[
        // Written out, because the window's length fixes the node's state.
        optional("n", ArgKind::Integer { min: 3 }),
        // A number that may follow a param, so that it can be tuned while
        // the graph runs.
        optional("limit", ArgKind::Number),
    ],
    // The input's rate, channels and units, unchanged.
    rule: Rule::Same,
};

/// Makes the node for one call. The checker has already seen to it that the
/// arguments are of the kinds declared above; what only this function knows
/// about them is checked here, and said of the call in the spec.
pub fn build(call: &Call<'_>) -> Result<Box<dyn Node>, String> {
    let window = call.whole("n").unwrap_or(5);
    if window % 2 == 0 {
        return Err(format!(
            "the window is {window} samples, and a median wants an odd number"
        ));
    }
    Ok(Box::new(Despike {
        window: window as usize,
        limit: call.number("limit").unwrap_or(3.0),
    }))
}

/// Scales a median absolute deviation to a standard deviation.
const ROBUST: f64 = 1.4826;

/// The node as written: its parameters, and no signal state.
pub struct Despike {
    pub window: usize,
    pub limit: f64,
}

impl Node for Despike {
    fn kind(&self) -> &'static str {
        "despike"
    }

    fn bind(
        &self,
        inputs: &[SignalType],
        _domains: &mut Domains,
    ) -> Result<Box<dyn Stage>, BuildError> {
        arity(self.kind(), inputs, 1)?;
        Ok(Box::new(DespikeStage {
            // The type promised by `Rule::Same`. The graph checks it.
            ty: inputs[0].clone(),
            window: self.window,
            limit: self.limit,
        }))
    }
}

struct DespikeStage {
    ty: SignalType,
    window: usize,
    limit: f64,
}

impl Stage for DespikeStage {
    fn output(&self) -> SignalType {
        self.ty.clone()
    }

    /// Channels do not look at one another, so the engine may run them on
    /// different cores.
    fn coupling(&self) -> Coupling {
        Coupling::Independent
    }

    /// Everything the stage computes from. When a param elsewhere in the
    /// spec is set, a stage whose fingerprint is unchanged keeps its
    /// kernels; set `limit` and this one starts over, which costs it one
    /// window of history.
    fn fingerprint(&self) -> u64 {
        fingerprint(("despike", self.window, self.limit.to_bits()))
    }

    // One sample out for each sample in, and none held back: the default
    // `span` and `buffers` say exactly that.

    fn kernel(&self, lane: std::ops::Range<usize>) -> Box<dyn Kernel> {
        Box::new(DespikeKernel {
            history: vec![Vec::with_capacity(self.window); lane.len()],
            next: vec![0; lane.len()],
            scratch: Vec::with_capacity(self.window),
            window: self.window,
            limit: self.limit,
            lane,
        })
    }
}

/// The state and inner loop for some of the channels.
struct DespikeKernel {
    lane: std::ops::Range<usize>,
    window: usize,
    limit: f64,
    /// The last `window` samples of each lane channel, as a ring.
    history: Vec<Vec<f64>>,
    /// Where in each ring the next sample goes.
    next: Vec<usize>,
    scratch: Vec<f64>,
}

impl DespikeKernel {
    fn median(values: &mut [f64]) -> f64 {
        let count = values.len();
        let (below, at, _) = values.select_nth_unstable_by(count / 2, f64::total_cmp);
        let at = *at;
        if count % 2 == 1 {
            return at;
        }
        // An even count, while the window is filling: midway between the
        // two in the middle.
        let under = below.iter().copied().fold(f64::NEG_INFINITY, f64::max);
        (under + at) / 2.0
    }
}

impl Kernel for DespikeKernel {
    /// Called at a new run: after a gap in the sensor's samples, or when
    /// the stage starts over.
    fn reset(&mut self) {
        self.history.iter_mut().for_each(Vec::clear);
        self.next.fill(0);
    }

    /// The result must not depend on how the samples were cut into blocks,
    /// which holds here because the state after a sample is a function of
    /// the samples so far and nothing else.
    fn process(&mut self, inputs: &Inputs<'_>, span: Span, out: &mut [f64]) {
        let input = inputs.block(0);
        for (row, (index, channel)) in out
            .chunks_exact_mut(span.frames)
            .zip(self.lane.clone().enumerate())
        {
            let history = &mut self.history[index];
            let next = &mut self.next[index];
            for (y, &x) in row.iter_mut().zip(input.channel(channel)) {
                if history.len() < self.window {
                    history.push(x);
                } else {
                    history[*next] = x;
                }
                *next = (*next + 1) % self.window;

                self.scratch.clear();
                self.scratch.extend_from_slice(history);
                let median = Self::median(&mut self.scratch);
                for value in &mut self.scratch {
                    *value = (*value - median).abs();
                }
                let spread = ROBUST * Self::median(&mut self.scratch);
                *y = if (x - median).abs() > self.limit * spread {
                    median
                } else {
                    x
                };
            }
        }
    }
}
