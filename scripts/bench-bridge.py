#!/usr/bin/env python3
"""A/B benchmark driver for tio-bridge over its stdio protocol.

Feeds the bridge a deterministic simulated device, activates two columns,
and measures a steady-state window:

  - plot frame (TLPLOT) inter-arrival gaps, ms percentiles
  - streamValues event gaps
  - RSS samples (KiB) via ps
  - CPU seconds (rusage of the child)
  - the bridge's own session-loop profile lines (stderr,
    enabled here via TWINLEAF_LOOP_PROFILE=1)

Typical session — build the simulator once, run it in one terminal:

    cargo build --release -p twinleaf-tools --bin tio \
        --manifest-path vendor/twinleaf-rust/Cargo.toml
    vendor/twinleaf-rust/target/release/tio simulate --port 17855 --no-drop

(headless: wrap in `script -q /dev/null ...` so raw mode finds a pty),
then benchmark a release bridge in another:

    cargo build --release --manifest-path rust/tio-bridge/Cargo.toml
    scripts/bench-bridge.py rust/tio-bridge/target/release/tio-bridge

To compare against another revision, check it out in a git worktree
(remember `git submodule update --init vendor/twinleaf-rust`), build its
bridge the same way, and run this driver against both binaries with the
same simulator instance.

The active-column selection assumes the simulator's schema (stream 1,
two sine channels at route "/"); pass --columns to override.
"""

import argparse
import json
import resource
import statistics
import subprocess
import sys
import threading
import time
import os


def parse_args():
    parser = argparse.ArgumentParser(
        description="Benchmark tio-bridge against a simulated device."
    )
    parser.add_argument("bridge", help="path to the tio-bridge binary")
    parser.add_argument(
        "--url",
        default="udp://127.0.0.1:17855",
        help="device URL to connect to (default: %(default)s)",
    )
    parser.add_argument(
        "--warmup",
        type=float,
        default=5.0,
        help="seconds to stream before the measurement window (default: %(default)s)",
    )
    parser.add_argument(
        "--duration",
        type=float,
        default=60.0,
        help="measurement window in seconds (default: %(default)s)",
    )
    parser.add_argument(
        "--columns",
        default='[{"route":"/","streamId":1,"columnIndex":0},'
        '{"route":"/","streamId":1,"columnIndex":1}]',
        help="JSON array of column keys to activate",
    )
    parser.add_argument(
        "--out",
        help="write the full result JSON here (a summary always prints to stdout)",
    )
    return parser.parse_args()


def gap_stats(times):
    if len(times) < 3:
        return None
    gaps = sorted((b - a) * 1000.0 for a, b in zip(times, times[1:]))

    def quantile(p):
        return gaps[min(len(gaps) - 1, int(p * len(gaps)))]

    return {
        "count": len(times),
        "mean_ms": statistics.fmean(gaps),
        "p50_ms": quantile(0.50),
        "p90_ms": quantile(0.90),
        "p99_ms": quantile(0.99),
        "max_ms": gaps[-1],
    }


def main():
    args = parse_args()
    env = dict(os.environ, TWINLEAF_LOOP_PROFILE="1")
    proc = subprocess.Popen(
        [args.bridge],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )

    profile_lines = []

    def read_stderr():
        for raw in proc.stderr:
            line = raw.decode(errors="replace").rstrip()
            if "profile session.loop" in line:
                profile_lines.append(line)

    threading.Thread(target=read_stderr, daemon=True).start()

    rss_samples = []
    stop = threading.Event()

    def sample_rss():
        while not stop.is_set():
            try:
                out = subprocess.run(
                    ["ps", "-o", "rss=", "-p", str(proc.pid)],
                    capture_output=True,
                    text=True,
                ).stdout.strip()
                if out:
                    rss_samples.append((time.monotonic(), int(out)))
            except Exception:
                pass
            stop.wait(0.5)

    threading.Thread(target=sample_rss, daemon=True).start()

    def send(cmd):
        proc.stdin.write((json.dumps(cmd) + "\n").encode())
        proc.stdin.flush()

    plot_times = []
    value_times = []
    event_counts = {}
    state = {"streaming_at": None, "fatal": None}
    out = proc.stdout

    def pump(deadline):
        """Read stdout until the deadline; record frame/event timestamps."""
        while time.monotonic() < deadline:
            line = out.readline()
            if not line:
                state["fatal"] = "bridge stdout closed"
                return
            now = time.monotonic()
            if line.startswith(b"TLPLOT"):
                length = int(line.split()[2])
                payload = out.read(length)
                if payload is None or len(payload) != length:
                    state["fatal"] = "short plot payload"
                    return
                plot_times.append(now)
                continue
            try:
                event = json.loads(line)
            except Exception:
                continue
            kind = event.get("type", "?")
            event_counts[kind] = event_counts.get(kind, 0) + 1
            if kind == "streamValues":
                value_times.append(now)
            elif kind == "status":
                if event.get("state") == "streaming" and state["streaming_at"] is None:
                    state["streaming_at"] = now
            elif kind == "error":
                sys.stderr.write("bridge error: %s\n" % event.get("message"))

    send({"type": "connect", "url": args.url})

    deadline = time.monotonic() + 30
    while (
        state["streaming_at"] is None
        and state["fatal"] is None
        and time.monotonic() < deadline
    ):
        pump(min(deadline, time.monotonic() + 0.25))
    if state["streaming_at"] is None:
        print(json.dumps({"error": state["fatal"] or "never reached streaming state"}))
        proc.kill()
        return 1

    send({"type": "setActiveColumns", "columns": json.loads(args.columns)})

    pump(time.monotonic() + args.warmup)

    window_start = time.monotonic()
    plot_before = len(plot_times)
    value_before = len(value_times)
    pump(window_start + args.duration)
    window_end = time.monotonic()

    send({"type": "shutdown"})
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    stop.set()
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)

    window_rss = [rss for t, rss in rss_samples if window_start <= t <= window_end]
    result = {
        "bridge": args.bridge,
        "url": args.url,
        "duration_s": window_end - window_start,
        "plot": gap_stats(plot_times[plot_before:]),
        "stream_values": gap_stats(value_times[value_before:]),
        "rss_kib": {
            "min": min(window_rss) if window_rss else None,
            "median": statistics.median(window_rss) if window_rss else None,
            "max": max(window_rss) if window_rss else None,
        },
        "cpu_s": usage.ru_utime + usage.ru_stime,
        "events": event_counts,
        "profile_tail": profile_lines[-4:],
    }
    if args.out:
        with open(args.out, "w") as f:
            json.dump(result, f, indent=2)
    print(
        json.dumps(
            {key: result[key] for key in ("plot", "rss_kib", "cpu_s")}, indent=2
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
