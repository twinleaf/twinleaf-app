// SPDX-License-Identifier: Apache-2.0

#![allow(dead_code)]

mod direct {
    include!("main.rs");

    use std::ffi::CStr;
    use std::os::raw::c_char;

    pub struct TwinleafRuntime {
        command_tx: Sender<ClientCommand>,
        thread: Option<thread::JoinHandle<()>>,
    }

    #[repr(C)]
    pub struct FfiRpcArg {
        tag: u8,
        bool_value: u8,
        int_value: i64,
        uint_value: u64,
        double_value: f64,
        string_value: *const c_char,
    }

    #[no_mangle]
    pub extern "C" fn twinleaf_runtime_create(
        callback: Option<EventCallback>,
        context: usize,
    ) -> *mut TwinleafRuntime {
        let Some(callback) = callback else {
            return std::ptr::null_mut();
        };

        let emitter = Emitter::callback(callback, context);
        emitter.status("ready", "Twinleaf Rust core ready");

        let (command_tx, command_rx) = channel::unbounded::<ClientCommand>();
        let runtime_emitter = emitter.clone();
        let thread = match thread::Builder::new()
            .name("twinleaf-runtime".into())
            .spawn(move || run_direct_runtime(command_rx, runtime_emitter))
        {
            Ok(thread) => thread,
            Err(err) => {
                emitter.error(format!("Failed to start Twinleaf runtime thread: {err}"));
                return std::ptr::null_mut();
            }
        };

        Box::into_raw(Box::new(TwinleafRuntime {
            command_tx,
            thread: Some(thread),
        }))
    }

    #[no_mangle]
    pub unsafe extern "C" fn twinleaf_runtime_destroy(runtime: *mut TwinleafRuntime) {
        if runtime.is_null() {
            return;
        }

        let mut runtime = Box::from_raw(runtime);
        let _ = runtime.command_tx.send(ClientCommand::Shutdown);
        if let Some(thread) = runtime.thread.take() {
            let _ = thread.join();
        }
    }

    #[no_mangle]
    pub unsafe extern "C" fn twinleaf_runtime_list_devices(
        runtime: *mut TwinleafRuntime,
        include_all: u8,
    ) {
        send_runtime_command(
            runtime,
            ClientCommand::ListDevices {
                include_all: Some(include_all != 0),
            },
        );
    }

    #[no_mangle]
    pub unsafe extern "C" fn twinleaf_runtime_connect(
        runtime: *mut TwinleafRuntime,
        url: *const c_char,
        route: *const c_char,
        log_path: *const c_char,
    ) {
        let Some(url) = c_string(url) else {
            return;
        };
        send_runtime_command(
            runtime,
            ClientCommand::Connect {
                url,
                route: c_string(route),
                log_path: c_string(log_path),
            },
        );
    }

    #[no_mangle]
    pub unsafe extern "C" fn twinleaf_runtime_open_log(
        runtime: *mut TwinleafRuntime,
        path: *const c_char,
    ) {
        let Some(path) = c_string(path) else {
            return;
        };
        send_runtime_command(runtime, ClientCommand::OpenLog { path });
    }

    #[no_mangle]
    pub unsafe extern "C" fn twinleaf_runtime_export_log(
        runtime: *mut TwinleafRuntime,
        request_id: *const c_char,
        source_path: *const c_char,
        output_path: *const c_char,
        format: u8,
    ) {
        let (Some(request_id), Some(source_path), Some(output_path)) = (
            c_string(request_id),
            c_string(source_path),
            c_string(output_path),
        ) else {
            return;
        };

        send_runtime_command(
            runtime,
            ClientCommand::ExportLog {
                request_id,
                source_path,
                output_path,
                format: export_format_from_code(format),
            },
        );
    }

    #[no_mangle]
    pub unsafe extern "C" fn twinleaf_runtime_disconnect(runtime: *mut TwinleafRuntime) {
        send_runtime_command(runtime, ClientCommand::Disconnect);
    }

    #[no_mangle]
    pub unsafe extern "C" fn twinleaf_runtime_check_upgrade(runtime: *mut TwinleafRuntime) {
        send_runtime_command(runtime, ClientCommand::CheckUpgrade);
    }

    #[no_mangle]
    pub unsafe extern "C" fn twinleaf_runtime_perform_upgrade(
        runtime: *mut TwinleafRuntime,
        route: *const c_char,
    ) {
        let Some(route) = c_string(route) else {
            return;
        };
        send_runtime_command(runtime, ClientCommand::PerformUpgrade { route });
    }

    #[no_mangle]
    pub unsafe extern "C" fn twinleaf_runtime_set_logging(
        runtime: *mut TwinleafRuntime,
        enabled: u8,
        log_path: *const c_char,
    ) {
        send_runtime_command(
            runtime,
            ClientCommand::SetLogging {
                enabled: enabled != 0,
                log_path: c_string(log_path),
            },
        );
    }

    #[no_mangle]
    pub unsafe extern "C" fn twinleaf_runtime_set_playback(
        runtime: *mut TwinleafRuntime,
        position: f64,
    ) {
        send_runtime_command(runtime, ClientCommand::SetPlayback { position });
    }

    #[no_mangle]
    pub unsafe extern "C" fn twinleaf_runtime_copy_view_data(
        runtime: *mut TwinleafRuntime,
        request_id: *const c_char,
        pane_id: usize,
        has_viewport_end: u8,
        viewport_end: f64,
    ) {
        let Some(request_id) = c_string(request_id) else {
            return;
        };
        send_runtime_command(
            runtime,
            ClientCommand::CopyViewData {
                request_id,
                pane_id: Some(pane_id),
                viewport_end: (has_viewport_end != 0).then_some(viewport_end),
            },
        );
    }

    /// Structured commands cross the boundary as a JSON `ClientCommand`.
    ///
    /// Commands whose payload is a list of records (plot panes, active
    /// columns, derived channels) used to be marshalled as a dozen parallel
    /// C arrays, which meant every new field cost another array on both
    /// sides. `ClientCommand` already derives `Deserialize`, so encoding the
    /// command on the Swift side is both less code and immune to the arrays
    /// silently falling out of step.
    ///
    /// Returns false if the pointer is null or the payload does not parse.
    #[no_mangle]
    pub unsafe extern "C" fn twinleaf_runtime_send_command_json(
        runtime: *mut TwinleafRuntime,
        json: *const c_char,
    ) -> bool {
        let Some(text) = c_string(json) else {
            return false;
        };

        match serde_json::from_str::<ClientCommand>(&text) {
            Ok(command) => {
                send_runtime_command(runtime, command);
                true
            }
            Err(_) => false,
        }
    }

    #[no_mangle]
    pub unsafe extern "C" fn twinleaf_runtime_call_rpc(
        runtime: *mut TwinleafRuntime,
        request_id: *const c_char,
        route: *const c_char,
        name: *const c_char,
        arg_json: *const c_char,
    ) {
        let (Some(request_id), Some(route), Some(name)) =
            (c_string(request_id), c_string(route), c_string(name))
        else {
            return;
        };

        send_runtime_command(
            runtime,
            ClientCommand::CallRpc {
                request_id,
                route,
                name,
                arg: json_arg(arg_json),
            },
        );
    }

    #[no_mangle]
    pub unsafe extern "C" fn twinleaf_runtime_call_rpc_value(
        runtime: *mut TwinleafRuntime,
        request_id: *const c_char,
        route: *const c_char,
        name: *const c_char,
        arg: *const FfiRpcArg,
    ) {
        let (Some(request_id), Some(route), Some(name)) =
            (c_string(request_id), c_string(route), c_string(name))
        else {
            return;
        };

        send_runtime_command(
            runtime,
            ClientCommand::CallRpc {
                request_id,
                route,
                name,
                arg: ffi_rpc_arg(arg),
            },
        );
    }

    fn run_direct_runtime(command_rx: Receiver<ClientCommand>, emitter: Emitter) {
        let mut session: Option<(Sender<SessionCommand>, thread::JoinHandle<()>)> = None;
        let mut playback: Option<PlaybackSession> = None;

        while let Ok(command) = command_rx.recv() {
            match command {
                ClientCommand::ListDevices { include_all } => {
                    let devices = list_available_devices(include_all.unwrap_or(false));
                    emitter.emit(&json!({
                        "type": "deviceList",
                        "devices": devices
                    }));
                }
                ClientCommand::Connect {
                    url,
                    route,
                    log_path,
                } => {
                    emitter.debug(format!("direct connect command received for {url}"));
                    stop_direct_session(&mut session);
                    playback = None;
                    let (tx, rx) = channel::unbounded();
                    let session_emitter = emitter.clone();
                    let handle = match thread::Builder::new()
                        .name("twinleaf-session".into())
                        .spawn(move || run_session(url, route, log_path, rx, session_emitter))
                    {
                        Ok(handle) => handle,
                        Err(err) => {
                            emitter.error(format!("Failed to start session thread: {err}"));
                            continue;
                        }
                    };
                    session = Some((tx, handle));
                }
                ClientCommand::SetLogging { enabled, log_path } => {
                    if let Some((tx, _)) = &session {
                        let _ = tx.send(SessionCommand::SetLogging { enabled, log_path });
                    } else {
                        emitter.debug("direct logging change ignored; no active streaming session");
                    }
                }
                ClientCommand::OpenLog { path } => {
                    emitter.debug(format!("direct openLog command received for {path}"));
                    stop_direct_session(&mut session);
                    match load_log_file(&path, &emitter) {
                        Ok(session_state) => {
                            emitter.status("inspection", format!("Opened log file {path}"));
                            emitter.emit(&json!({
                                "type": "metadata",
                                "devices": &session_state.devices
                            }));
                            session_state.emit_state(&emitter);
                            session_state.emit_plot(&emitter);
                            session_state.emit_stream_values(&emitter);
                            playback = Some(session_state);
                        }
                        Err(err) => {
                            playback = None;
                            emitter.error(format!("Failed to open log file: {err}"));
                        }
                    }
                }
                ClientCommand::ExportLog {
                    request_id,
                    source_path,
                    output_path,
                    format,
                } => {
                    emitter.status(
                        "exporting",
                        format!("Exporting {} as {:?}", source_path, format),
                    );
                    let result = export_log_file(&source_path, &output_path, format, &emitter);
                    emit_export_result(&emitter, request_id, output_path, format, result);
                }
                ClientCommand::Disconnect => {
                    emitter.debug("direct disconnect command received");
                    stop_direct_session(&mut session);
                    playback = None;
                    emitter.status("disconnected", "Disconnected");
                }
                ClientCommand::SetPlayback { position } => {
                    if let Some(playback) = playback.as_mut() {
                        playback.set_position(position);
                        playback.emit_state(&emitter);
                        playback.emit_plot(&emitter);
                        playback.emit_stream_values(&emitter);
                    }
                }
                ClientCommand::CopyViewData {
                    request_id,
                    pane_id,
                    viewport_end,
                } => {
                    if let Some((tx, _)) = &session {
                        let _ = tx.send(SessionCommand::CopyViewData {
                            request_id,
                            pane_id,
                            viewport_end,
                        });
                    } else if let Some(playback) = playback.as_mut() {
                        let end = viewport_end.unwrap_or(playback.position);
                        let pane = playback
                            .plot_panes
                            .iter()
                            .find(|pane| Some(pane.id) == pane_id)
                            .or_else(|| playback.plot_panes.first());
                        let (columns, view) = pane
                            .map(|pane| (pane_columns_set(pane), pane.view.clone()))
                            .unwrap_or_else(|| {
                                (playback.active_columns.clone(), playback.view.clone())
                            });
                        let text = build_view_data_tsv(
                            &playback.column_states,
                            &columns,
                            &view,
                            Some(playback.clamp_position(end)),
                        );
                        emit_view_data(&emitter, request_id, Ok(text));
                    } else {
                        emit_view_data(
                            &emitter,
                            request_id,
                            Err("No active data view".to_string()),
                        );
                    }
                }
                ClientCommand::SetActiveColumns { columns } => {
                    if let Some((tx, _)) = &session {
                        let _ = tx.send(SessionCommand::SetActiveColumns(columns));
                    } else if let Some(playback) = playback.as_mut() {
                        playback.set_active_columns(columns);
                        emit_active_columns(&emitter, &playback.active_columns);
                        playback.emit_plot(&emitter);
                        playback.emit_stream_values(&emitter);
                    }
                }
                ClientCommand::SetPlotPanes { panes } => {
                    if let Some((tx, _)) = &session {
                        let _ = tx.send(SessionCommand::SetPlotPanes(panes));
                    } else if let Some(playback) = playback.as_mut() {
                        playback.set_plot_panes(panes);
                        emit_active_columns(&emitter, &playback.active_columns);
                        playback.emit_state(&emitter);
                        playback.emit_plot(&emitter);
                        playback.emit_stream_values(&emitter);
                    }
                }
                ClientCommand::SetDerivedChannels { channels } => {
                    if let Some((tx, _)) = &session {
                        let _ = tx.send(SessionCommand::SetDerivedChannels(channels));
                    } else if let Some(playback) = playback.as_mut() {
                        playback.set_derived_channels(channels);
                        playback.emit_plot(&emitter);
                        playback.emit_stream_values(&emitter);
                    }
                }
                ClientCommand::SetView { view } => {
                    if let Some((tx, _)) = &session {
                        let _ = tx.send(SessionCommand::SetView(view));
                    } else if let Some(playback) = playback.as_mut() {
                        playback.set_view(view);
                        playback.emit_state(&emitter);
                        playback.emit_plot(&emitter);
                        playback.emit_stream_values(&emitter);
                    }
                }
                ClientCommand::CallRpc {
                    request_id,
                    route,
                    name,
                    arg,
                } => {
                    if let Some((tx, _)) = &session {
                        let _ = tx.send(SessionCommand::CallRpc {
                            request_id,
                            route,
                            name,
                            arg,
                        });
                    }
                }
                ClientCommand::CheckUpgrade => {
                    if let Some((tx, _)) = &session {
                        let _ = tx.send(SessionCommand::CheckUpgrade);
                    }
                }
                ClientCommand::PerformUpgrade { route } => {
                    if let Some((tx, _)) = &session {
                        let _ = tx.send(SessionCommand::PerformUpgrade { route });
                    }
                }
                ClientCommand::Shutdown => {
                    emitter.debug("direct shutdown command received");
                    stop_direct_session(&mut session);
                    emitter.status("exiting", "Rust core shutting down");
                    break;
                }
            }
        }

        stop_direct_session(&mut session);
    }

    fn stop_direct_session(session: &mut Option<(Sender<SessionCommand>, thread::JoinHandle<()>)>) {
        if let Some((tx, handle)) = session.take() {
            let _ = tx.send(SessionCommand::Stop);
            let _ = handle.join();
        }
    }

    unsafe fn send_runtime_command(runtime: *mut TwinleafRuntime, command: ClientCommand) {
        if let Some(runtime) = runtime.as_ref() {
            let _ = runtime.command_tx.send(command);
        }
    }

    unsafe fn c_string(value: *const c_char) -> Option<String> {
        if value.is_null() {
            return None;
        }
        CStr::from_ptr(value).to_str().ok().map(ToString::to_string)
    }

    unsafe fn json_arg(value: *const c_char) -> Option<Value> {
        let text = c_string(value)?;
        if text.is_empty() || text == "null" {
            return None;
        }
        serde_json::from_str(&text).ok()
    }

    unsafe fn ffi_rpc_arg(value: *const FfiRpcArg) -> Option<Value> {
        let value = value.as_ref()?;
        match value.tag {
            1 => Some(Value::Bool(value.bool_value != 0)),
            2 => c_string(value.string_value).map(Value::String),
            3 => serde_json::Number::from_f64(value.double_value).map(Value::Number),
            4 => Some(Value::Number(value.int_value.into())),
            5 => Some(Value::Number(value.uint_value.into())),
            _ => None,
        }
    }

    fn plot_mode_from_code(value: u8) -> PlotMode {
        match value {
            1 => PlotMode::Fft,
            _ => PlotMode::Timeseries,
        }
    }

    fn decimation_method_from_code(value: u8) -> DecimationMethod {
        match value {
            0 => DecimationMethod::None,
            _ => DecimationMethod::Fpcs,
        }
    }

    fn detrend_from_code(value: u8) -> DetrendMethod {
        match value {
            0 => DetrendMethod::None,
            1 => DetrendMethod::Mean,
            2 => DetrendMethod::Linear,
            3 => DetrendMethod::Quadratic,
            _ => DetrendMethod::Quadratic,
        }
    }

    fn export_format_from_code(value: u8) -> ExportFormat {
        match value {
            1 => ExportFormat::Hdf5,
            _ => ExportFormat::Csv,
        }
    }
}
