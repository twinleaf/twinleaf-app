//! The command line: check a spec, draw it, run it over a recording, or
//! serve it as a device.
//!
//! It is here, in the library, and not in the `tiodsp` binary, so that a
//! private build is the same program with more functions: its `main` makes
//! a [`Library`], adds to it, and calls [`run`]. Everything a user of
//! `tiodsp` knows then holds for it, under its own name.

use crate::figure::{self, Format};
use crate::lang::{self, check::format_rate, diag, Analysis, Severity};
use crate::library::Library;
use crate::run::{run_log, RunError, RunOptions};
use crate::serve::{MountSpec, ServeError, ServeOptions, Server};
use std::fs::File;
use std::io::BufWriter;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const USAGE: &str = "\
usage:
  tiodsp check <spec>         parse and check a spec; exit non-zero on error
  tiodsp functions            list the functions a spec may call
  tiodsp graph <spec> --dot   print the spec's graph in Graphviz DOT
  tiodsp graph <spec> --typst print it as a Typst figure, to include or edit
  tiodsp graph <spec> --pdf <file> | --svg <file> [--packages <dir>]
                              compile that figure
  tiodsp run <spec> --log <recording> [--csv <file>] [--threads <n>]
                              [--block <samples>] [--set <param>=<value>]...
                              run a spec over a recording

  tiodsp serve <spec> --mount <url>[=/<n>[@/<route>]]... [--port <n>]
                              [--all-interfaces] [--threads <n>]
                              serve the sensors and the spec's outputs as one
                              device tree

--threads and --block change how fast a run goes, never its numbers.
--mount puts a sensor at /0, /1, ... in the order given, or at /<n>. A
sensor behind a hub is named by its route there: <url>=/0@/1.
--packages names a directory to find the figure's Typst packages in, laid
out as preview/<name>/<version>. Those not there are looked for where Typst
keeps them, and then fetched from Typst Universe.
Not written yet: `run --hdf5`.
";

/// The command line was wrong, or a file could not be read or written.
const USAGE_ERROR: u8 = 2;

/// Runs the command line the process was started with, for a build whose
/// specs may call the functions in `library`.
pub fn run(library: Library) -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    run_with(&library, &args)
}

/// Runs one command line. `args` is everything after the program's name.
pub fn run_with(library: &Library, args: &[&str]) -> ExitCode {
    let me = library.name();
    let usage = USAGE.replace("tiodsp", me);
    let with_spec = |name: &str, then: &mut dyn FnMut(Spec<'_>, &Analysis) -> ExitCode| {
        with_spec(library, name, then)
    };
    match args {
        ["check", spec] => with_spec(spec, &mut |spec, analysis| {
            print!("{}", summary(spec.name, analysis));
            ExitCode::SUCCESS
        }),
        ["functions"] => {
            print!("{}", functions(library));
            ExitCode::SUCCESS
        }
        ["graph", spec, "--dot"] | ["graph", "--dot", spec] => {
            with_spec(spec, &mut |spec, analysis| {
                let stem = spec.path.file_stem().and_then(|stem| stem.to_str());
                print!(
                    "{}",
                    lang::dot::dot(&analysis.program, stem.unwrap_or("spec"))
                );
                ExitCode::SUCCESS
            })
        }
        ["run", spec, flags @ ..] => match RunFlags::parse(flags) {
            Ok(mut flags) => {
                flags.options.library = library.clone();
                with_spec(spec, &mut |spec, analysis| {
                    over_log(me, &spec, analysis, &flags)
                })
            }
            Err(message) => {
                eprintln!("{me}: {message}\n\n{usage}");
                ExitCode::from(USAGE_ERROR)
            }
        },
        ["serve", spec, flags @ ..] => match serve_options(flags) {
            Ok(mut options) => {
                options.run.library = library.clone();
                serve(me, spec, options)
            }
            Err(message) => {
                eprintln!("{me}: {message}\n\n{usage}");
                ExitCode::from(USAGE_ERROR)
            }
        },
        ["graph", spec, "--typst"] | ["graph", "--typst", spec] => {
            with_spec(spec, &mut |spec, analysis| {
                print!("{}", lang::typst::figure(&analysis.program, spec.name));
                ExitCode::SUCCESS
            })
        }
        ["graph", spec, flag @ ("--pdf" | "--svg"), file, rest @ ..] => {
            let packages = match rest {
                [] => None,
                ["--packages", directory] => Some(Path::new(directory)),
                _ => {
                    eprint!("{usage}");
                    return ExitCode::from(USAGE_ERROR);
                }
            };
            let format = match *flag {
                "--pdf" => Format::Pdf,
                _ => Format::Svg,
            };
            with_spec(spec, &mut |spec, analysis| {
                draw(me, &spec, analysis, format, Path::new(file), packages)
            })
        }
        ["help" | "--help" | "-h"] => {
            print!("{usage}");
            ExitCode::SUCCESS
        }
        _ => {
            eprint!("{usage}");
            ExitCode::from(USAGE_ERROR)
        }
    }
}

/// The functions of a library, each as it is written. One that is checked
/// and cannot run yet says so.
fn functions(library: &Library) -> String {
    let mut out = String::new();
    for function in library.functions() {
        let runs = library.runs(function.name);
        let note = if runs {
            ""
        } else {
            "   (checked; cannot run yet)"
        };
        out.push_str(&format!("  {}{note}\n", function.usage));
    }
    out
}

/// Compiles a spec's figure and writes it to `file`.
fn draw(
    me: &str,
    spec: &Spec<'_>,
    analysis: &Analysis,
    format: Format,
    file: &Path,
    packages: Option<&Path>,
) -> ExitCode {
    let source = lang::typst::document(&analysis.program, spec.name);
    let made = match figure::render(&source, format, packages) {
        Ok(made) => made,
        Err(error) => {
            eprintln!("{me}: {error}");
            return ExitCode::FAILURE;
        }
    };
    if let Err(error) = std::fs::write(file, made) {
        eprintln!("{me}: cannot write {}: {error}", file.display());
        return ExitCode::from(USAGE_ERROR);
    }
    ExitCode::SUCCESS
}

/// A spec that was read.
struct Spec<'a> {
    name: &'a str,
    path: &'a Path,
    source: &'a str,
}

/// Reads and checks a spec, prints its diagnostics, and runs `then` if it
/// has no errors.
fn with_spec(
    library: &Library,
    name: &str,
    then: &mut dyn FnMut(Spec<'_>, &Analysis) -> ExitCode,
) -> ExitCode {
    let me = library.name();
    let path = Path::new(name);
    let source = match std::fs::read_to_string(path) {
        Ok(source) => source,
        Err(error) => {
            eprintln!("{me}: cannot read {name}: {error}");
            return ExitCode::from(USAGE_ERROR);
        }
    };
    let analysis = lang::analyze_with(&source, library);
    if !analysis.diagnostics.is_empty() {
        eprintln!("{}", diag::render_all(&analysis.diagnostics, name, &source));
    }
    let count = |severity| {
        analysis
            .diagnostics
            .iter()
            .filter(|d| d.severity == severity)
            .count()
    };
    let (errors, warnings) = (count(Severity::Error), count(Severity::Warning));
    if errors > 0 {
        eprintln!(
            "error: {name} does not check: {}{}",
            plural(errors, "error"),
            if warnings > 0 {
                format!(", {}", plural(warnings, "warning"))
            } else {
                String::new()
            }
        );
        return ExitCode::FAILURE;
    }
    if warnings > 0 {
        eprintln!("warning: {name}: {}", plural(warnings, "warning"));
    }
    let spec = Spec {
        name,
        path,
        source: &source,
    };
    then(spec, &analysis)
}

fn plural(count: usize, noun: &str) -> String {
    if count == 1 {
        format!("1 {noun}")
    } else {
        format!("{count} {noun}s")
    }
}

/// What a spec that checks will do: its sources, params and outputs.
fn summary(name: &str, analysis: &Analysis) -> String {
    let program = &analysis.program;
    let mut out = format!("{name}: ok\n");
    let signal = |node: usize| {
        let ty = &program.nodes[node].ty;
        let names: Vec<&str> = ty.channels.iter().map(|c| c.name.as_str()).collect();
        let mut text = format!("{} ch ({})", names.len(), names.join(", "));
        let unit = &ty
            .channels
            .get(0)
            .expect("a channel set is never empty")
            .unit;
        if !unit.is_none() && ty.channels.iter().all(|c| c.unit == *unit) {
            text.push_str(&format!(", {unit}"));
        }
        format!("{text}, {}", program.sampling_of(node))
    };
    for source in &program.sources {
        out.push_str(&format!(
            "  source {:<10} {}  {}\n",
            source.name,
            source.path,
            signal(source.node)
        ));
    }
    for param in &program.params {
        let unit = if param.unit.is_none() {
            String::new()
        } else {
            format!(" {}", param.unit)
        };
        let range = match param.range {
            Some((low, high)) => format!("  [{low} .. {high}]"),
            None => String::new(),
        };
        out.push_str(&format!(
            "  param  {:<10} {}{unit}{range}\n",
            param.name, param.value
        ));
    }
    let latency = crate::lower::latency(program);
    for (output, latency) in program.outputs.iter().zip(latency) {
        out.push_str(&format!(
            "  out    {:<10} /255/{}  {}{}\n",
            output.name,
            output.name,
            signal(output.node),
            late(latency)
        ));
    }
    out
}

/// How late an output runs, when the graph makes it wait at all.
fn late(latency: crate::lower::Latency) -> String {
    let ms = |seconds: f64| format!("{} ms", (seconds * 1e4).round() / 10.0);
    match (latency.seconds > 0.0, latency.if_interpolated > 0.0) {
        (false, false) => String::new(),
        (true, false) => format!(", {} late", ms(latency.seconds)),
        (false, true) => format!(
            ", {} late if its arms sample at different instants",
            ms(latency.if_interpolated)
        ),
        (true, true) => format!(
            ", {} late, or {} if its arms sample at different instants",
            ms(latency.seconds),
            ms(latency.seconds + latency.if_interpolated)
        ),
    }
}

/// The flags of `tiodsp run`.
struct RunFlags {
    log: PathBuf,
    csv: Option<PathBuf>,
    options: RunOptions,
}

impl RunFlags {
    fn parse(flags: &[&str]) -> Result<Self, String> {
        let mut log = None;
        let mut csv = None;
        let mut options = RunOptions::default();
        let mut flags = flags.iter();
        while let Some(flag) = flags.next() {
            let mut value = || {
                flags
                    .next()
                    .copied()
                    .ok_or_else(|| format!("`{flag}` needs a value"))
            };
            let count = |text: &str| {
                text.parse::<usize>()
                    .ok()
                    .filter(|n| *n > 0)
                    .ok_or_else(|| {
                        format!("`{flag}` takes a whole number above zero, not `{text}`")
                    })
            };
            match *flag {
                "--log" => log = Some(PathBuf::from(value()?)),
                "--csv" => csv = Some(PathBuf::from(value()?)),
                "--threads" => options.graph.threads = count(value()?)?,
                "--block" => options.block_rows = count(value()?)?,
                "--set" => {
                    let setting = value()?;
                    let parsed = setting
                        .split_once('=')
                        .and_then(|(name, value)| Some((name.to_owned(), value.parse().ok()?)));
                    options.set.push(
                        parsed.ok_or_else(|| {
                            format!("`--set` takes `param=number`, not `{setting}`")
                        })?,
                    );
                }
                other => return Err(format!("`run` has no flag `{other}`")),
            }
        }
        Ok(Self {
            log: log.ok_or("`run` needs `--log <recording>`")?,
            csv,
            options,
        })
    }

    /// Where an output's CSV goes: the file asked for when there is one
    /// output, and that name with the output's worked in when there are more.
    fn csv_for(&self, output: &str, outputs: usize) -> Option<PathBuf> {
        let path = self.csv.as_ref()?;
        if outputs == 1 {
            return Some(path.clone());
        }
        let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("out");
        let extension = path.extension().and_then(|e| e.to_str()).unwrap_or("csv");
        Some(path.with_file_name(format!("{stem}.{output}.{extension}")))
    }
}

fn over_log(me: &str, spec: &Spec<'_>, analysis: &Analysis, flags: &RunFlags) -> ExitCode {
    let recording = match run_log(&analysis.program, &flags.log, &flags.options) {
        Ok(recording) => recording,
        Err(RunError::Spec(diagnostics)) => {
            eprintln!("{}", diag::render_all(&diagnostics, spec.name, spec.source));
            eprintln!("error: {} does not fit {}", spec.name, flags.log.display());
            return ExitCode::FAILURE;
        }
        Err(error @ (RunError::Io(_) | RunError::Setting(_))) => {
            eprintln!("{me}: {error}");
            return ExitCode::from(USAGE_ERROR);
        }
        Err(error) => {
            eprintln!("error: {error}");
            return ExitCode::FAILURE;
        }
    };
    let count = recording.outputs.len();
    for output in &recording.outputs {
        let mut line = match output.spectrum {
            true => format!(
                "  out    {:<10} {} bins of {} Hz",
                output.name,
                output.frames(),
                1.0 / output.rate
            ),
            false => format!(
                "  out    {:<10} {} samples at {}",
                output.name,
                output.frames(),
                format_rate(output.rate)
            ),
        };
        if output.runs.len() > 1 {
            line.push_str(&format!(", in {} stretches", output.runs.len()));
        }
        if let Some(path) = flags.csv_for(&output.name, count) {
            let written = File::create(&path).and_then(|file| {
                let mut out = BufWriter::new(file);
                output.write_csv(&mut out)?;
                std::io::Write::flush(&mut out)
            });
            if let Err(error) = written {
                eprintln!("{me}: cannot write {}: {error}", path.display());
                return ExitCode::from(USAGE_ERROR);
            }
            line.push_str(&format!(" -> {}", path.display()));
        }
        println!("{line}");
    }
    ExitCode::SUCCESS
}

/// The flags of `tiodsp serve`.
fn serve_options(flags: &[&str]) -> Result<ServeOptions, String> {
    let mut options = ServeOptions {
        mounts: Vec::new(),
        port: 0,
        all_interfaces: false,
        run: RunOptions::default(),
    };
    let mut flags = flags.iter();
    while let Some(flag) = flags.next() {
        let mut value = || {
            flags
                .next()
                .copied()
                .ok_or_else(|| format!("`{flag}` needs a value"))
        };
        match *flag {
            "--mount" => {
                let mount = mount(value()?, options.mounts.len())?;
                if options
                    .mounts
                    .iter()
                    .any(|known| known.prefix == mount.prefix)
                {
                    return Err(format!("two sensors are mounted at {}", mount.prefix));
                }
                options.mounts.push(mount);
            }
            "--port" => {
                let text = value()?;
                options.port = text
                    .parse()
                    .map_err(|_| format!("`--port` takes a port number, not `{text}`"))?;
            }
            "--threads" => {
                let text = value()?;
                options.run.graph.threads = text
                    .parse()
                    .ok()
                    .filter(|threads| *threads > 0)
                    .ok_or_else(|| {
                        format!("`--threads` takes a whole number above zero, not `{text}`")
                    })?;
            }
            "--all-interfaces" => options.all_interfaces = true,
            other => return Err(format!("`serve` has no flag `{other}`")),
        }
    }
    if options.mounts.is_empty() {
        return Err("`serve` needs at least one `--mount <url>`".to_owned());
    }
    Ok(options)
}

/// Reads `<url>`, `<url>=/<n>` or `<url>=/<n>@/<route>`.
fn mount(text: &str, position: usize) -> Result<MountSpec, String> {
    let route = |text: &str| {
        text.parse()
            .map_err(|_| format!("`{text}` is not a route such as `/0`"))
    };
    let (url, placed) = match text.rsplit_once('=') {
        Some((url, placed)) => (url, Some(placed)),
        None => (text, None),
    };
    let (prefix, source) = match placed.map(|placed| placed.split_once('@')) {
        None => (format!("/{position}"), "/"),
        Some(None) => (placed.unwrap_or("").to_owned(), "/"),
        Some(Some((prefix, source))) => (prefix.to_owned(), source),
    };
    if url.is_empty() {
        return Err(format!("`--mount {text}` names no sensor"));
    }
    Ok(MountSpec {
        url: url.to_owned(),
        prefix: route(&prefix)?,
        source: route(source)?,
    })
}

fn serve(me: &str, name: &str, options: ServeOptions) -> ExitCode {
    let source = match std::fs::read_to_string(name) {
        Ok(source) => source,
        Err(error) => {
            eprintln!("{me}: cannot read {name}: {error}");
            return ExitCode::from(USAGE_ERROR);
        }
    };
    match Server::start(source.clone(), options) {
        Ok(server) => {
            println!(
                "{me}: serving {name} at {}, outputs at {}",
                server.endpoint(),
                server.route()
            );
            server.wait();
            ExitCode::SUCCESS
        }
        Err(ServeError::Spec(diagnostics)) => {
            eprintln!("{}", diag::render_all(&diagnostics, name, &source));
            eprintln!("error: {name} does not check");
            ExitCode::FAILURE
        }
        Err(error) => {
            eprintln!("{me}: {error}");
            ExitCode::from(USAGE_ERROR)
        }
    }
}
