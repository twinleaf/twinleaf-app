//! The private function, from every side a user meets it: the checker, the
//! engine, and the device.

use labdsp::{despike, library};
use std::sync::Arc;
use twinleaf::proto::rpc::{Method, RpcError};
use twinleaf::proto::sync::Epoch;
use twinleaf::proto::SessionId;
use twinleaf_dsp::client::{read_spec, write_spec, TransferError};
use twinleaf_dsp::lang;
use twinleaf_dsp::lang::builtins::{Rule, Signals};
use twinleaf_dsp::lower::{lower, LowerError, SourceFacts};
use twinleaf_dsp::run::RunOptions;
use twinleaf_dsp::serve::Device;
use twinleaf_dsp::{Block, Graph, Options, RunId};

const SPEC: &str = "\
source a = /0/field @rate(500) @channels(x, y) @unit(nT)

param limit = 3 [1 .. 10]

out clean : nT = a | despike(n = 7, limit = limit)
";

/// The graph of a spec that reads one source.
fn graph(source: &str) -> Result<Graph, LowerError> {
    let analysis = lang::analyze_with(source, &library());
    assert!(!analysis.has_errors(), "{:?}", analysis.diagnostics);
    let facts = SourceFacts {
        epoch: Epoch::UNIX,
        timebase: SessionId::new(1),
        origin: 0.0,
    };
    let program = &analysis.program;
    let options = Options {
        threads: 1,
        ..Options::default()
    };
    lower(program, &[facts], &program.declared(), options)
}

/// A slow wave with a little wobble, and a spike every so often.
fn sample(channel: usize, index: usize) -> f64 {
    let t = index as f64 * 0.01 + channel as f64;
    let wobble = 0.05 * ((index * 7919 + channel * 104_729) % 97) as f64 / 97.0;
    let spike = if index % 61 == 30 { 25.0 } else { 0.0 };
    t.sin() + wobble + spike
}

/// Feeds samples `0..count` in blocks of `size` and returns the output,
/// channel by channel.
fn run(graph: &mut Graph, count: usize, size: usize) -> Vec<Vec<f64>> {
    let ty = graph.sources().next().unwrap().1.clone();
    let mut out = vec![Vec::new(); ty.channels.len()];
    let mut first = 0;
    while first < count {
        let frames = size.min(count - first);
        let data = (0..ty.channels.len())
            .flat_map(|channel| (first..first + frames).map(move |i| sample(channel, i)))
            .collect();
        graph
            .tick(vec![Block {
                domain: ty.domain,
                run: RunId(1),
                first: first as u64,
                frames,
                channels: Arc::clone(&ty.channels),
                data,
            }])
            .unwrap();
        let block = graph.output("clean").unwrap();
        for (channel, row) in out.iter_mut().enumerate() {
            row.extend_from_slice(block.channel(channel));
        }
        first += frames;
    }
    out
}

/// The filter as its description reads, written without reference to how
/// the kernel does it: sort, take the middle.
fn hampel(input: &[f64], window: usize, limit: f64) -> Vec<f64> {
    let median = |values: &[f64]| {
        let mut sorted = values.to_vec();
        sorted.sort_by(f64::total_cmp);
        let middle = sorted.len() / 2;
        if sorted.len() % 2 == 1 {
            sorted[middle]
        } else {
            (sorted[middle - 1] + sorted[middle]) / 2.0
        }
    };
    (0..input.len())
        .map(|i| {
            let recent = &input[i.saturating_sub(window - 1)..=i];
            let middle = median(recent);
            let away: Vec<f64> = recent.iter().map(|x| (x - middle).abs()).collect();
            if (input[i] - middle).abs() > limit * 1.4826 * median(&away) {
                middle
            } else {
                input[i]
            }
        })
        .collect()
}

#[test]
fn the_function_is_this_builds_and_no_other() {
    let ours = library();
    assert_eq!(ours.name(), "labdsp");
    assert!(ours.find("despike").is_some() && ours.runs("despike"));
    assert!(!lang::analyze_with(SPEC, &ours).has_errors());

    // To the public build the same text names a function there is not.
    let public = lang::analyze(SPEC);
    assert!(public.has_errors());
    assert_eq!(public.diagnostics[0].code, Some("E0203"));
    assert_eq!(
        public.diagnostics[0].message,
        "there is no function `despike`"
    );

    // A name can be given once: not twice, and not a public one's.
    assert!(ours
        .clone()
        .with(despike::FUNCTION, despike::build)
        .is_err());
    let mut taken = despike::FUNCTION;
    taken.name = "lowpass";
    assert!(library().with(taken, despike::build).is_err());

    // Nor can a function be added that changes the rate, or takes more
    // than one signal: those are typed by rules that are not open yet.
    for (rule, signals) in [
        (Rule::Decimate, Signals::One),
        (Rule::Resample, Signals::One),
        (Rule::Same, Signals::Arms),
    ] {
        let mut other = despike::FUNCTION;
        other.name = "other";
        other.rule = rule;
        other.signals = signals;
        assert!(library().with(other, despike::build).is_err(), "{rule:?}");
    }
}

#[test]
fn a_spec_runs_the_private_stage_and_gets_what_the_filter_is_said_to_do() {
    let count = 1500;
    let output = run(&mut graph(SPEC).unwrap(), count, 64);
    for (channel, got) in output.iter().enumerate() {
        let input: Vec<f64> = (0..count).map(|i| sample(channel, i)).collect();
        assert!(*got == hampel(&input, 7, 3.0), "channel {channel} differs");

        // Which is to say: the spikes are gone, and the rest is as it came.
        let mut untouched = 0;
        for i in 0..count {
            if i % 61 == 30 {
                assert!(
                    (got[i] - input[i]).abs() > 20.0,
                    "the spike at {i} is still there"
                );
            } else {
                untouched += usize::from(got[i] == input[i]);
            }
        }
        assert!(
            untouched > count * 9 / 10,
            "only {untouched} passed untouched"
        );
    }
}

#[test]
fn how_the_samples_are_cut_into_blocks_changes_nothing() {
    let whole = run(&mut graph(SPEC).unwrap(), 1000, 4096);
    for size in [1, 37, 500] {
        assert!(
            run(&mut graph(SPEC).unwrap(), 1000, size) == whole,
            "blocks of {size}"
        );
    }
}

#[test]
fn what_only_the_function_knows_is_wrong_is_said_of_the_call() {
    // The checker passes any whole number of 3 or more. That a median
    // wants an odd one is the function's own business.
    let even = SPEC.replace("n = 7", "n = 8");
    let analysis = lang::analyze_with(&even, &library());
    assert!(!analysis.has_errors());
    let Err(error) = graph(&even) else {
        panic!("an even window was built");
    };
    assert!(matches!(
        error,
        LowerError::Private {
            function: "despike",
            ..
        }
    ));
    assert_eq!(
        error.to_string(),
        "`despike`: the window is 8 samples, and a median wants an odd number"
    );
    let node = &analysis.program.nodes[error.node().unwrap()];
    assert_eq!(node.span.text(&even), "a | despike(n = 8, limit = limit)");
}

#[test]
fn the_device_goes_by_the_builds_name_and_takes_its_functions() {
    let options = RunOptions {
        library: library(),
        ..RunOptions::default()
    };
    let mut device = Device::new(SPEC.to_owned(), options).unwrap();
    let mut call = |name: &str, args: &[u8]| device.call(Method::ByName(name.as_bytes()), args);

    assert_eq!(call("dev.name", &[]).unwrap(), b"labdsp");
    // The param the private function follows is a setting like any other.
    let limit = |reply: Vec<u8>| f64::from_le_bytes(reply.try_into().unwrap());
    assert_eq!(limit(call("dsp.limit", &[]).unwrap()), 3.0);
    assert_eq!(
        limit(call("dsp.limit", &4.5f64.to_le_bytes()).unwrap()),
        4.5
    );
    assert_eq!(
        read_spec(&mut call).unwrap(),
        SPEC.replace("limit = 3 ", "limit = 4.5 ")
    );

    // A new text that calls it is taken, and one that calls a function
    // nobody has is refused, by the same check with the same library.
    let wider = SPEC.replace("n = 7", "n = 11");
    write_spec(&mut call, &wider).unwrap();
    assert_eq!(read_spec(&mut call).unwrap(), wider);
    let unknown = SPEC.replace("despike(", "smooth(");
    assert_eq!(
        write_spec(&mut call, &unknown),
        Err(TransferError::Call(RpcError::Invalid))
    );
    assert_eq!(read_spec(&mut call).unwrap(), wider);
}
