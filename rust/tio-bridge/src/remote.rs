// SPDX-License-Identifier: Apache-2.0

// Sharing a live session with other machines, and viewing a shared one.
//
// The machine that owns the devices hands the app the packets it would write
// to a `.tio` log: the session's metadata as UPDATE packets, then every packet
// the session receives, sample packets gathered per stream into frames of a few
// tens of milliseconds. The app carries the frames to viewers. A viewer feeds
// them to `run_remote_session`, which decodes them exactly as a log is decoded
// and plots and logs them as a device session does. A viewer sends nothing
// back, so a remote session is read-only.
//
// This file is included by `main.rs`.

/// What a publish frame carries, as its first byte.
const PUBLISH_METADATA: u8 = 1;
const PUBLISH_SAMPLES: u8 = 2;
const PUBLISH_PACKETS: u8 = 3;
/// How long sample packets gather before their frame goes out.
const PUBLISH_FLUSH_INTERVAL: Duration = Duration::from_millis(30);

/// One publish frame: the kind, the stream id (0 unless samples), the route as
/// length-prefixed text (empty unless samples), then whole packets in wire
/// form.
fn publish_frame(kind: u8, route: &str, stream_id: u8, packets: &[u8]) -> Vec<u8> {
    let mut frame = Vec::with_capacity(4 + route.len() + packets.len());
    frame.push(kind);
    frame.push(stream_id);
    frame.extend_from_slice(&(route.len() as u16).to_le_bytes());
    frame.extend_from_slice(route.as_bytes());
    frame.extend_from_slice(packets);
    frame
}

/// Gathers a live session's packets into publish frames while sharing is on.
#[derive(Default)]
struct PublishTap {
    enabled: bool,
    /// Sample packets not yet sent, by route and stream.
    samples: std::collections::BTreeMap<(DeviceRoute, u8), Vec<u8>>,
    last_flush: Option<Instant>,
}

impl PublishTap {
    fn set_enabled(&mut self, enabled: bool, devices: &[DeviceDto], emitter: &Emitter) {
        self.enabled = enabled;
        self.samples.clear();
        self.last_flush = None;
        self.publish_metadata(devices, emitter);
    }

    /// Sends every device's metadata as the packets a log starts with. The app
    /// keeps the newest frame for viewers that join later.
    fn publish_metadata(&mut self, devices: &[DeviceDto], emitter: &Emitter) {
        if !self.enabled {
            return;
        }
        let mut bytes = Vec::new();
        for device in devices {
            let Some(metadata) = &device.full_metadata else {
                continue;
            };
            match metadata.metadata_packets() {
                Ok(packets) => {
                    for packet in &packets {
                        bytes.extend_from_slice(packet.as_bytes());
                    }
                }
                Err(err) => emitter.debug(format!(
                    "metadata of route {} could not be shared: {err:?}",
                    device.route
                )),
            }
        }
        emitter.emit_publish(&publish_frame(PUBLISH_METADATA, "", 0, &bytes));
    }

    /// Takes one packet the session received. Sample packets wait for their
    /// stream's next frame. Any other packet goes out at once, behind the
    /// samples that came before it, so a viewer reads it where it happened.
    fn observe(&mut self, packet: &tio::Packet, emitter: &Emitter) {
        if !self.enabled {
            return;
        }
        if let Payload::Samples(samples) = packet.payload() {
            self.samples
                .entry((packet.route(), samples.stream_id.value()))
                .or_default()
                .extend_from_slice(packet.as_bytes());
            self.last_flush.get_or_insert_with(Instant::now);
        } else {
            self.flush(emitter);
            emitter.emit_publish(&publish_frame(PUBLISH_PACKETS, "", 0, packet.as_bytes()));
        }
    }

    fn flush_if_due(&mut self, emitter: &Emitter) {
        if self
            .last_flush
            .is_some_and(|at| at.elapsed() >= PUBLISH_FLUSH_INTERVAL)
        {
            self.flush(emitter);
        }
    }

    fn flush(&mut self, emitter: &Emitter) {
        self.last_flush = None;
        for ((route, stream_id), bytes) in &mut self.samples {
            if bytes.is_empty() {
                continue;
            }
            emitter.emit_publish(&publish_frame(
                PUBLISH_SAMPLES,
                &route.to_string(),
                *stream_id,
                bytes,
            ));
            bytes.clear();
        }
    }
}

/// The decoding state of a shared session being viewed.
struct RemoteIngest {
    url: String,
    parser: PacketParser,
    devices: Vec<DeviceDto>,
    /// The devices as last told to the app, to tell a change from a repeat.
    devices_signature: String,
    column_states: HashMap<ColumnKeyDto, ColumnState>,
    data_start: Option<f64>,
    data_end: Option<f64>,
    time_reference_start: Option<f64>,
    latest_stream_timestamp_by_route: HashMap<DeviceRoute, f64>,
}

impl RemoteIngest {
    fn new(url: String) -> Self {
        Self {
            url,
            parser: PacketParser::new(false),
            devices: Vec::new(),
            devices_signature: String::new(),
            column_states: HashMap::new(),
            data_start: None,
            data_end: None,
            time_reference_start: None,
            latest_stream_timestamp_by_route: HashMap::new(),
        }
    }

    /// Decodes one received frame, which holds whole packets, logs them, and
    /// adds their samples to the plot history.
    fn ingest(
        &mut self,
        data: &[u8],
        logger: &mut PacketLogger,
        active_columns: &HashSet<ColumnKeyDto>,
        plot_panes: &[PlotPaneConfig],
        max_window_seconds: f64,
        emitter: &Emitter,
    ) -> RemoteIngestOutcome {
        let mut outcome = RemoteIngestOutcome::default();
        let mut saw_metadata = false;
        let mut rest = data;

        while !rest.is_empty() {
            let (packet, used) = match tio::Packet::from_slice_prefix(rest) {
                Ok(parsed) => parsed,
                Err(err) => {
                    // Frames hold whole packets, so this is a damaged frame.
                    emitter.debug(format!("dropped {} unreadable byte(s): {err:?}", rest.len()));
                    break;
                }
            };
            rest = &rest[used..];
            emit_tio_log_message(
                &packet,
                self.latest_stream_timestamp_by_route
                    .get(&packet.route())
                    .copied(),
                emitter,
            );
            saw_metadata |= matches!(packet.payload(), Payload::Metadata(..));
            logger.write_packet(&packet);
            if let Err(err) = self.parser.push_packet(&packet) {
                emitter.debug(format!("rejected packet on {}: {err}", packet.route()));
            }
        }
        // A frame is all the samples there are for now, so none wait in the
        // parser for a fuller batch.
        self.parser.flush();

        if saw_metadata {
            outcome.metadata_changed = self.refresh_devices();
        }

        while let Some(batch) = self.parser.pop_batch() {
            let route = batch.route();
            if let Some(first_row) = batch.row(0) {
                let batch_start = first_row.timestamp_begin();
                if batch_start.is_finite() {
                    self.data_start =
                        Some(self.data_start.map_or(batch_start, |s| s.min(batch_start)));
                }
            }
            if let Some(&batch_end) = batch.timestamps().last() {
                if batch_end.is_finite() {
                    self.data_end = Some(self.data_end.map_or(batch_end, |e| e.max(batch_end)));
                    self.latest_stream_timestamp_by_route
                        .insert(route, batch_end);
                }
            }
            self.time_reference_start = earliest_time(
                self.time_reference_start,
                batch_time_reference_start(&batch),
            );
            process_batch(
                &batch,
                &mut self.column_states,
                active_columns,
                plot_panes,
                max_window_seconds,
                None,
            );
            outcome.samples += batch.len();
            if matches!(
                batch
                    .boundary()
                    .and_then(|boundary| boundary.change.as_ref()),
                Some(Change::SessionChanged { .. } | Change::Restarted { .. })
            ) {
                flush_route_history(&route.to_string(), &mut self.column_states);
                outcome.device_reset = true;
            }
        }
        outcome
    }

    /// Rebuilds the device list from the metadata the parser holds. Returns
    /// whether it differs from the list last reported.
    fn refresh_devices(&mut self) -> bool {
        let mut devices: Vec<DeviceDto> = self
            .parser
            .routes()
            .into_iter()
            .filter_map(|route| {
                let metadata = self.parser.metadata(route)?;
                Some(metadata_to_device_dto(
                    self.url.clone(),
                    &route,
                    &metadata,
                    Vec::new(),
                ))
            })
            .collect();
        if devices.is_empty() {
            return false;
        }
        sort_devices_leaf_first(&mut devices, None);
        let signature = serde_json::to_string(&devices).unwrap_or_default();
        if signature == self.devices_signature {
            return false;
        }
        self.devices_signature = signature;
        for (key, state) in build_column_states(&devices) {
            self.column_states.entry(key).or_insert(state);
        }
        self.devices = devices;
        true
    }
}

#[derive(Default)]
struct RemoteIngestOutcome {
    samples: usize,
    metadata_changed: bool,
    device_reset: bool,
}

/// A session whose packets come from another machine's shared session rather
/// than from a device. It plots and logs like `run_session`, and refuses RPCs.
fn run_remote_session(
    label: String,
    log_path: Option<String>,
    command_rx: Receiver<SessionCommand>,
    emitter: Emitter,
) {
    let _command_drain = SessionCommandDrain {
        command_rx: command_rx.clone(),
        emitter: emitter.clone(),
    };
    const READ_ONLY: &str = "A shared session is read-only";

    emitter.status("connecting", format!("Connecting to {label}"));
    let mut remote = RemoteIngest::new(format!("labcast://{label}"));
    let mut active_columns: HashSet<ColumnKeyDto> = HashSet::new();
    let mut view = ViewConfig::default();
    let mut plot_panes = default_plot_panes(&view);
    let mut fft_workers: HashMap<usize, FftWorker> = HashMap::new();
    let mut derived_channels: Vec<DerivedChannelDto> = Vec::new();
    let mut derived_worker = DerivedWorker::new();
    let mut logger = PacketLogger::new(log_path, &emitter);
    let mut last_stream_value_emit = Instant::now();
    let mut last_log_flush = Instant::now();
    let mut last_log_progress_packets = 0;
    let tick = ticker(Duration::from_millis(10));
    let plot_tick = ticker(Duration::from_millis(33));

    loop {
        enum RemoteWake {
            Command(Result<SessionCommand, flume::RecvError>),
            Tick,
            PlotTick,
        }
        let wake = flume::Selector::new()
            .recv(&command_rx, RemoteWake::Command)
            .recv(&tick, |_| RemoteWake::Tick)
            .recv(&plot_tick, |_| RemoteWake::PlotTick)
            .wait();
        let command = match wake {
            RemoteWake::PlotTick => {
                let _ = emit_live_plot(
                    &emitter,
                    &remote.column_states,
                    &active_columns,
                    &plot_panes,
                    &mut fft_workers,
                );
                continue;
            }
            RemoteWake::Tick => {
                if !derived_channels.is_empty() {
                    update_derived_channels(
                        &derived_channels,
                        &mut remote.column_states,
                        &mut derived_worker,
                        live_retention_seconds_for_panes(&plot_panes, &view, &derived_channels),
                    );
                }
                if last_stream_value_emit.elapsed() >= Duration::from_millis(100) {
                    emit_stream_values(&emitter, &remote.column_states);
                    last_stream_value_emit = Instant::now();
                }
                if last_log_flush.elapsed() >= Duration::from_secs(1) {
                    logger.flush();
                    if logger.packets_written != last_log_progress_packets {
                        logger.emit_progress(
                            &emitter,
                            remote.data_start,
                            remote.data_end,
                            remote.time_reference_start,
                        );
                        last_log_progress_packets = logger.packets_written;
                    }
                    last_log_flush = Instant::now();
                }
                continue;
            }
            RemoteWake::Command(Ok(command)) => command,
            RemoteWake::Command(Err(_)) => SessionCommand::Stop,
        };

        match command {
            SessionCommand::Stop => {
                logger.flush();
                emitter.status("disconnected", "Stopped streaming");
                return;
            }
            SessionCommand::RemoteIngest(data) => {
                let outcome = remote.ingest(
                    &data,
                    &mut logger,
                    &active_columns,
                    &plot_panes,
                    live_retention_seconds_for_panes(&plot_panes, &view, &derived_channels),
                    &emitter,
                );
                if outcome.device_reset {
                    fft_workers.clear();
                }
                if outcome.metadata_changed {
                    emitter.status(
                        "metadata",
                        format!("Loaded metadata for {} device(s)", remote.devices.len()),
                    );
                    emit_metadata_devices(&emitter, &remote.devices);
                    emitter.status("streaming", format!("Streaming from {label}"));
                }
            }
            SessionCommand::SetActiveColumns(columns) => {
                update_default_pane_columns(&mut plot_panes, columns, &view);
                active_columns = active_columns_for_panes(&plot_panes);
                fft_workers.clear();
                hydrate_fpcs(&mut remote.column_states, &plot_panes, &emitter);
                emit_active_columns(&emitter, &active_columns);
            }
            SessionCommand::SetLogging { enabled, log_path } => {
                logger.set_enabled(enabled, log_path, &remote.devices, &emitter);
                if logger.is_enabled() {
                    logger.emit_progress(
                        &emitter,
                        remote.data_start,
                        remote.data_end,
                        remote.time_reference_start,
                    );
                    last_log_progress_packets = logger.packets_written;
                } else {
                    last_log_progress_packets = 0;
                }
            }
            SessionCommand::SetView(new_view) => {
                view = new_view;
                apply_view_to_all_panes(&mut plot_panes, &view);
                active_columns = active_columns_for_panes(&plot_panes);
                fft_workers.clear();
                hydrate_fpcs(&mut remote.column_states, &plot_panes, &emitter);
            }
            SessionCommand::SetPlotPanes(panes) => {
                plot_panes = panes;
                active_columns = active_columns_for_panes(&plot_panes);
                fft_workers.clear();
                hydrate_fpcs(&mut remote.column_states, &plot_panes, &emitter);
                emit_active_columns(&emitter, &active_columns);
            }
            SessionCommand::SetDerivedChannels(channels) => {
                for channel in &channels {
                    let changed = derived_channels
                        .iter()
                        .find(|existing| existing.key == channel.key)
                        .is_none_or(|existing| existing != channel);
                    if changed {
                        remote.column_states.remove(&channel.key);
                    }
                }
                let retained: HashSet<_> =
                    channels.iter().map(|channel| channel.key.clone()).collect();
                remote
                    .column_states
                    .retain(|key, _| !key.is_derived() || retained.contains(key));
                derived_channels = channels;
            }
            SessionCommand::CopyViewData {
                request_id,
                pane_id,
                viewport_end,
            } => {
                let pane = plot_panes
                    .iter()
                    .find(|pane| Some(pane.id) == pane_id)
                    .or_else(|| plot_panes.first());
                let (columns, view) = pane
                    .map(|pane| (pane_columns_set(pane), pane.view.clone()))
                    .unwrap_or_else(|| (active_columns.clone(), view.clone()));
                let text =
                    build_view_data_tsv(&remote.column_states, &columns, &view, viewport_end);
                emit_view_data(&emitter, request_id, Ok(text));
            }
            SessionCommand::CallRpc { request_id, .. } => {
                emitter.emit(&json!({
                    "type": "rpcResult",
                    "requestId": request_id,
                    "ok": false,
                    "error": READ_ONLY
                }));
            }
            SessionCommand::CallRawRpc { request_id, .. } => {
                emit_raw_rpc_error(&emitter, &request_id, READ_ONLY, None);
            }
            // A viewer has no device to share, flash, or measure the link of.
            SessionCommand::SetPublishing(_)
            | SessionCommand::CheckUpgrade
            | SessionCommand::PerformUpgrade { .. }
            | SessionCommand::ResetHealthCounters => {}
        }
    }
}

#[cfg(test)]
mod remote_tests {
    use super::*;
    use twinleaf::proto::data as wire;
    use twinleaf::proto::{ColumnId, SegmentId, SessionId, StreamId};

    const STREAM_ID: u8 = 1;
    const RATE_HZ: u32 = 1000;

    extern "C" fn discard(_kind: u32, _data: *const u8, _len: usize, _context: usize) {}

    /// The metadata of a device with one stream of one `f32` column.
    fn metadata_packets(route: DeviceRoute) -> Vec<tio::Packet> {
        let stream_id = StreamId::new(STREAM_ID);
        let records = [
            wire::Metadata::Device(wire::Device {
                session: SessionId::new(42),
                n_streams: 1,
                name: "VMR",
                serial: "SN123",
                firmware: "fw",
                protocol: 0,
            }),
            wire::Metadata::Stream(wire::Stream {
                stream_id,
                n_columns: 1,
                n_segments: 1,
                sample_size: 4,
                buf_samples: 128,
                name: "field",
            }),
            wire::Metadata::Segment(wire::Segment {
                stream_id,
                segment_id: SegmentId::new(0),
                flags: wire::SegmentFlags::default(),
                epoch: Epoch::UNIX,
                timeref_serial: "clock",
                timeref_session: SessionId::new(7),
                start_time: 0,
                sampling_rate: RATE_HZ,
                decimation: 1,
                filter_cutoff: 0.0,
                filter_type: wire::FilterType::NONE,
            }),
            wire::Metadata::Column(wire::Column {
                stream_id,
                index: ColumnId::new(0),
                data_type: DataType::F32,
                name: "x",
                units: "nT",
                description: "field along x",
            }),
        ];
        records
            .into_iter()
            .map(|record| {
                tio::Packet::metadata(record, wire::MetadataFlags::default(), route).unwrap()
            })
            .collect()
    }

    /// A packet of `count` samples numbered from `first`, each sample's value
    /// its own number.
    fn sample_packet(first: u32, count: u32, route: DeviceRoute) -> tio::Packet {
        let mut data = Vec::new();
        for n in first..first + count {
            data.extend_from_slice(&(n as f32).to_le_bytes());
        }
        tio::Packet::samples(STREAM_ID, 0, first, &data, route).unwrap()
    }

    /// What a publisher emits for a session reaches a viewer's plot history
    /// whole and in order: the tap's frames, stripped of their headers as the
    /// app strips them, decode to every sample that went in.
    #[test]
    fn a_shared_session_decodes_to_every_sample_in_order() {
        thread_local! {
            static FRAMES: std::cell::RefCell<Vec<Vec<u8>>> = const { std::cell::RefCell::new(Vec::new()) };
        }
        extern "C" fn collect(kind: u32, data: *const u8, len: usize, _context: usize) {
            if kind == EVENT_PUBLISH {
                let frame = unsafe { std::slice::from_raw_parts(data, len) }.to_vec();
                FRAMES.with(|frames| frames.borrow_mut().push(frame));
            }
        }

        let route = DeviceRoute::from_str("/0").unwrap();
        let publisher = Emitter::callback(collect, 0);
        let mut seed = PacketParser::new(false);
        for packet in metadata_packets(route) {
            seed.push_packet(&packet).unwrap();
        }
        let metadata = seed.metadata(route).expect("complete metadata");
        let devices = vec![metadata_to_device_dto(
            "serial://test".to_string(),
            &route,
            &metadata,
            Vec::new(),
        )];

        let mut tap = PublishTap::default();
        // Nothing leaves while sharing is off.
        tap.observe(&sample_packet(0, 4, route), &publisher);
        tap.flush(&publisher);
        assert!(FRAMES.with(|frames| frames.borrow().is_empty()));

        tap.set_enabled(true, &devices, &publisher);
        const PACKETS: u32 = 500;
        const PER_PACKET: u32 = 4;
        for index in 0..PACKETS {
            tap.observe(&sample_packet(index * PER_PACKET, PER_PACKET, route), &publisher);
            if index % 8 == 7 {
                tap.flush(&publisher);
            }
            if index == 250 {
                // A packet that is not samples keeps its place in the order.
                tap.observe(&tio::Packet::heartbeat_session(42, route), &publisher);
            }
        }
        tap.flush(&publisher);

        let frames = FRAMES.with(|frames| frames.take());
        assert_eq!(frames[0][0], PUBLISH_METADATA);
        let sample_frames = frames
            .iter()
            .filter(|frame| frame[0] == PUBLISH_SAMPLES)
            .count();
        assert!(sample_frames < PACKETS as usize / 4, "samples are batched");

        let viewer = Emitter::callback(discard, 0);
        let mut logger = PacketLogger::new(None, &viewer);
        let mut remote = RemoteIngest::new("labcast://test".to_string());
        let plot_panes = default_plot_panes(&ViewConfig::default());
        let mut samples = 0;
        let mut metadata_changes = 0;
        for frame in &frames {
            let route_len = usize::from(u16::from_le_bytes([frame[2], frame[3]]));
            let outcome = remote.ingest(
                &frame[4 + route_len..],
                &mut logger,
                &HashSet::new(),
                &plot_panes,
                f64::INFINITY,
                &viewer,
            );
            samples += outcome.samples;
            metadata_changes += usize::from(outcome.metadata_changed);
        }

        assert_eq!(metadata_changes, 1);
        assert_eq!(remote.devices.len(), 1);
        assert_eq!(remote.devices[0].meta.name, "VMR");
        assert_eq!(remote.devices[0].meta.serial_number, "SN123");
        let stream = &remote.devices[0].streams[0];
        assert_eq!(stream.effective_sampling_rate, f64::from(RATE_HZ));
        assert_eq!(stream.columns[0].units, "nT");

        let total = (PACKETS * PER_PACKET) as usize;
        assert_eq!(samples, total);
        let key = ColumnKeyDto::raw("/0".to_string(), STREAM_ID, 0);
        let points = &remote.column_states[&key].raw;
        assert_eq!(points.len(), total);
        for (n, point) in points.iter().enumerate() {
            assert_eq!(point.y, n as f64, "sample {n} out of order");
        }
        // Timestamps advance by one sample period, with no gap or repeat.
        let period = 1.0 / f64::from(RATE_HZ);
        for (earlier, later) in points.iter().zip(points.iter().skip(1)) {
            assert!((later.x - earlier.x - period).abs() < 1e-9);
        }
    }
}
