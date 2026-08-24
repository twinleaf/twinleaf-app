// SPDX-License-Identifier: Apache-2.0

use crossbeam::channel::{self, Receiver, Sender};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs::{File, OpenOptions};
use std::io::{self, BufRead, BufWriter, Write};
use std::ops::RangeInclusive;
use std::panic::{self, AssertUnwindSafe};
use std::path::Path;
use std::str::FromStr;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use twinleaf::data::ColumnOp;
use twinleaf::data::{
    BoundaryReason, ColumnArray, DeviceMetadataSnapshot, LogFile, PacketParser, SampleBatch,
};
use twinleaf::device::capture::{read_capture, CaptureReadout, CaptureRpc};
use twinleaf::device::discovery::{Discovery, DiscoveryConfig, DiscoveryEvent, PortInterface};
use twinleaf::device::{
    DeviceEvent, DeviceTree, NamedRoute, RpcClient, RpcDescriptor, RpcRegistryError, TreeEvent,
    TreeItem,
};
#[cfg(feature = "firmware")]
use twinleaf::firmware::{self, FirmwareCatalog, FlashEvent, StopOutcome, UpdateStatus};
use twinleaf::tio::proto::meta::MetadataEpoch;
use twinleaf::tio::proto::{DeviceRoute, Payload, RpcMetaFlags, RpcMethod, RpcValue, RpcValueType};
use twinleaf::tio::proxy;
use twinleaf::{tio, Device};
use twinleaf_tools::tui::spectral::WelchOp;

const EVENT_JSON: u32 = 0;
const EVENT_PLOT: u32 = 1;
const EVENT_TYPED: u32 = 2;

const TYPED_STATUS: u16 = 1;
const TYPED_ERROR: u16 = 2;
const TYPED_DEBUG: u16 = 3;
const TYPED_DEVICE_LIST: u16 = 4;
const TYPED_METADATA: u16 = 5;
const TYPED_PLAYBACK: u16 = 6;
const TYPED_LOG_PROGRESS: u16 = 7;
const TYPED_STREAM_VALUES: u16 = 8;
const TYPED_VIEW_DATA: u16 = 9;
const TYPED_EXPORT_RESULT: u16 = 10;
const TYPED_LOG_MESSAGE: u16 = 11;
const TYPED_RPC_RESULT: u16 = 12;
const TYPED_RPC_INVALIDATED: u16 = 13;
const TYPED_DEVICE_EVENT: u16 = 14;
const TYPED_ACTIVE_COLUMNS: u16 = 15;
const TYPED_PROXY_EVENT: u16 = 16;

const RPC_METADATA_RETRY_ATTEMPTS: usize = 3;
const RPC_METADATA_RETRY_DELAY: Duration = Duration::from_millis(50);
const CONNECTION_STARTUP_TIMEOUT: Duration = Duration::from_secs(60);
const CONNECTION_METADATA_RETRY_DELAY: Duration = Duration::from_millis(500);
const RPC_METADATA_RECOVERY_INTERVAL: Duration = Duration::from_secs(1);
/// Minimum spacing between metadata/RPC refreshes triggered by a device reset,
/// so a device that reboots repeatedly can't keep the session busy refetching.
const DEVICE_RESET_REFRESH_COOLDOWN: Duration = Duration::from_secs(5);

/// Health diagnostics (mirrors `tio health`): jitter window length, the sample
/// count before drift/PPM is trusted, the stale-stream floor, and the emit
/// cadence to the UI.
const HEALTH_JITTER_WINDOW_SECONDS: u64 = 10;
const HEALTH_MIN_DRIFT_SAMPLES: u64 = 50;
const HEALTH_STALE_FLOOR: Duration = Duration::from_millis(2000);
const HEALTH_EMIT_INTERVAL: Duration = Duration::from_millis(500);

type EventCallback = extern "C" fn(kind: u32, data: *const u8, len: usize, context: usize);

#[derive(Clone)]
struct Emitter {
    sink: Arc<EmitterSink>,
    write_lock: Arc<Mutex<()>>,
}

#[allow(dead_code)]
enum EmitterSink {
    Stdout,
    Callback {
        callback: EventCallback,
        context: usize,
    },
}

impl Emitter {
    fn new() -> Self {
        Self {
            sink: Arc::new(EmitterSink::Stdout),
            write_lock: Arc::new(Mutex::new(())),
        }
    }

    #[allow(dead_code)]
    fn callback(callback: EventCallback, context: usize) -> Self {
        Self {
            sink: Arc::new(EmitterSink::Callback { callback, context }),
            write_lock: Arc::new(Mutex::new(())),
        }
    }

    fn emit<T: Serialize>(&self, value: &T) {
        match &*self.sink {
            EmitterSink::Callback { callback, context } => {
                if let Ok(value) = serde_json::to_value(value) {
                    if let Some(payload) = encode_typed_event(&value) {
                        let _guard = self.write_lock.lock().unwrap();
                        callback(EVENT_TYPED, payload.as_ptr(), payload.len(), *context);
                        return;
                    }
                    if let Ok(data) = serde_json::to_vec(&value) {
                        self.emit_json_bytes(&data);
                    }
                }
            }
            EmitterSink::Stdout => {
                if let Ok(data) = serde_json::to_vec(value) {
                    self.emit_json_bytes(&data);
                }
            }
        }
    }

    fn emit_json_bytes(&self, data: &[u8]) {
        let _guard = self.write_lock.lock().unwrap();
        match &*self.sink {
            EmitterSink::Stdout => {
                let mut stdout = io::stdout();
                let _ = stdout.write_all(data);
                let _ = writeln!(stdout);
                let _ = stdout.flush();
            }
            EmitterSink::Callback { callback, context } => {
                callback(EVENT_JSON, data.as_ptr(), data.len(), *context);
            }
        }
    }

    fn emit_plot_frame(
        &self,
        pane_id: usize,
        mode: PlotMode,
        viewport_end: Option<f64>,
        series: &[BinaryPlotSeries<'_>],
    ) -> io::Result<()> {
        let payload_len = binary_plot_payload_len(series)?;
        let _guard = self.write_lock.lock().unwrap();
        match &*self.sink {
            EmitterSink::Stdout => {
                let mut stdout = io::stdout();
                writeln!(stdout, "TLPLOT 1 {payload_len}")?;
                write_plot_payload(&mut stdout, pane_id, mode, viewport_end, series)?;
                stdout.flush()
            }
            EmitterSink::Callback { callback, context } => {
                let mut payload = Vec::with_capacity(payload_len);
                write_plot_payload(&mut payload, pane_id, mode, viewport_end, series)?;
                callback(EVENT_PLOT, payload.as_ptr(), payload.len(), *context);
                Ok(())
            }
        }
    }

    fn status(&self, state: &str, message: impl Into<String>) {
        self.emit(&json!({
            "type": "status",
            "state": state,
            "message": message.into()
        }));
    }

    fn error(&self, message: impl Into<String>) {
        self.emit(&json!({
            "type": "error",
            "message": message.into()
        }));
    }

    fn debug(&self, message: impl AsRef<str>) {
        if !bridge_debug_enabled() {
            return;
        }
        let message = message.as_ref();
        eprintln!("[tio-bridge] {message}");
        self.emit(&json!({
            "type": "debug",
            "message": message
        }));
    }
}

struct TypedEventWriter {
    data: Vec<u8>,
}

impl TypedEventWriter {
    fn new(event_type: u16) -> Self {
        let mut writer = Self { data: Vec::new() };
        writer.write_u16(event_type);
        writer
    }

    fn finish(self) -> Vec<u8> {
        self.data
    }

    fn write_u8(&mut self, value: u8) {
        self.data.push(value);
    }

    fn write_bool(&mut self, value: bool) {
        self.write_u8(u8::from(value));
    }

    fn write_u16(&mut self, value: u16) {
        self.data.extend(value.to_le_bytes());
    }

    fn write_u32(&mut self, value: u32) {
        self.data.extend(value.to_le_bytes());
    }

    fn write_u64(&mut self, value: u64) {
        self.data.extend(value.to_le_bytes());
    }

    fn write_i64(&mut self, value: i64) {
        self.data.extend(value.to_le_bytes());
    }

    fn write_f64(&mut self, value: f64) {
        self.data.extend(value.to_le_bytes());
    }

    fn write_len(&mut self, len: usize) {
        self.write_u32(len.min(u32::MAX as usize) as u32);
    }

    fn write_str(&mut self, value: &str) {
        let bytes = value.as_bytes();
        let len = bytes.len().min(u32::MAX as usize);
        self.write_len(len);
        self.data.extend(&bytes[..len]);
    }

    fn write_optional_str(&mut self, value: Option<&str>) {
        match value {
            Some(value) => {
                self.write_bool(true);
                self.write_str(value);
            }
            None => self.write_bool(false),
        }
    }

    fn write_optional_u64(&mut self, value: Option<u64>) {
        match value {
            Some(value) => {
                self.write_bool(true);
                self.write_u64(value);
            }
            None => self.write_bool(false),
        }
    }

    fn write_optional_f64(&mut self, value: Option<f64>) {
        match value {
            Some(value) if value.is_finite() => {
                self.write_bool(true);
                self.write_f64(value);
            }
            _ => self.write_bool(false),
        }
    }
}

fn encode_typed_event(value: &Value) -> Option<Vec<u8>> {
    let event_type = value.get("type")?.as_str()?;
    match event_type {
        "status" => encode_status_event(value),
        "error" => encode_message_event(TYPED_ERROR, value),
        "debug" => encode_message_event(TYPED_DEBUG, value),
        "deviceList" => encode_device_list_event(value),
        "metadata" => encode_metadata_event(value),
        "playback" => encode_playback_event(value),
        "logProgress" => encode_log_progress_event(value),
        "streamValues" => encode_stream_values_event(value),
        "viewData" => encode_view_data_event(value),
        "exportResult" => encode_export_result_event(value),
        "logMessage" => encode_log_message_event(value),
        "rpcResult" => encode_rpc_result_event(value),
        "rpcInvalidated" => encode_rpc_invalidated_event(value),
        "deviceEvent" => encode_device_event(value),
        "activeColumns" => encode_active_columns_event(value),
        "proxyEvent" => encode_proxy_event(value),
        _ => None,
    }
}

fn encode_status_event(value: &Value) -> Option<Vec<u8>> {
    let mut writer = TypedEventWriter::new(TYPED_STATUS);
    writer.write_str(value.get("state")?.as_str()?);
    writer.write_str(value.get("message")?.as_str()?);
    Some(writer.finish())
}

fn encode_message_event(event_type: u16, value: &Value) -> Option<Vec<u8>> {
    let mut writer = TypedEventWriter::new(event_type);
    writer.write_str(value.get("message")?.as_str()?);
    Some(writer.finish())
}

fn encode_device_list_event(value: &Value) -> Option<Vec<u8>> {
    let mut writer = TypedEventWriter::new(TYPED_DEVICE_LIST);
    write_available_devices(&mut writer, value.get("devices")?.as_array()?);
    Some(writer.finish())
}

fn encode_metadata_event(value: &Value) -> Option<Vec<u8>> {
    let mut writer = TypedEventWriter::new(TYPED_METADATA);
    write_devices(&mut writer, value.get("devices")?.as_array()?);
    Some(writer.finish())
}

fn encode_playback_event(value: &Value) -> Option<Vec<u8>> {
    let mut writer = TypedEventWriter::new(TYPED_PLAYBACK);
    writer.write_f64(value.get("start")?.as_f64()?);
    writer.write_f64(value.get("end")?.as_f64()?);
    writer.write_f64(value.get("position")?.as_f64()?);
    writer.write_optional_f64(optional_f64(value.get("recordingStart")));
    writer.write_optional_f64(optional_f64(value.get("timeReferenceStart")));
    Some(writer.finish())
}

fn encode_log_progress_event(value: &Value) -> Option<Vec<u8>> {
    let mut writer = TypedEventWriter::new(TYPED_LOG_PROGRESS);
    writer.write_u64(value.get("packets")?.as_u64()?);
    writer.write_u64(value.get("bytes")?.as_u64()?);
    writer.write_optional_u64(optional_u64(value.get("fileBytes")));
    writer.write_optional_f64(optional_f64(value.get("startSeconds")));
    writer.write_optional_f64(optional_f64(value.get("elapsedSeconds")));
    writer.write_optional_f64(optional_f64(value.get("timeReferenceStart")));
    writer.write_optional_u64(optional_u64(value.get("serializeErrors")));
    Some(writer.finish())
}

fn encode_stream_values_event(value: &Value) -> Option<Vec<u8>> {
    let mut writer = TypedEventWriter::new(TYPED_STREAM_VALUES);
    let values = value.get("values")?.as_array()?;
    writer.write_len(values.len());
    for item in values {
        write_column_key(&mut writer, item.get("key")?);
        writer.write_f64(item.get("value")?.as_f64()?);
    }
    Some(writer.finish())
}

fn encode_view_data_event(value: &Value) -> Option<Vec<u8>> {
    let mut writer = TypedEventWriter::new(TYPED_VIEW_DATA);
    writer.write_str(value.get("requestId")?.as_str()?);
    writer.write_bool(value.get("ok")?.as_bool()?);
    writer.write_optional_str(value.get("text").and_then(Value::as_str));
    writer.write_optional_u64(optional_u64(value.get("rows")));
    writer.write_optional_str(value.get("error").and_then(Value::as_str));
    Some(writer.finish())
}

fn encode_export_result_event(value: &Value) -> Option<Vec<u8>> {
    let mut writer = TypedEventWriter::new(TYPED_EXPORT_RESULT);
    writer.write_str(value.get("requestId")?.as_str()?);
    writer.write_bool(value.get("ok")?.as_bool()?);
    writer.write_optional_str(value.get("outputPath").and_then(Value::as_str));
    writer.write_optional_str(value.get("format").and_then(Value::as_str));
    writer.write_optional_u64(optional_u64(value.get("rows")));
    writer.write_optional_u64(optional_u64(value.get("bytes")));
    writer.write_optional_str(value.get("error").and_then(Value::as_str));
    Some(writer.finish())
}

fn encode_log_message_event(value: &Value) -> Option<Vec<u8>> {
    let mut writer = TypedEventWriter::new(TYPED_LOG_MESSAGE);
    writer.write_str(value.get("route")?.as_str()?);
    writer.write_f64(value.get("timestampSeconds")?.as_f64()?);
    writer.write_str(value.get("message")?.as_str()?);
    Some(writer.finish())
}

fn encode_rpc_result_event(value: &Value) -> Option<Vec<u8>> {
    let mut writer = TypedEventWriter::new(TYPED_RPC_RESULT);
    writer.write_str(value.get("requestId")?.as_str()?);
    writer.write_bool(value.get("ok")?.as_bool()?);
    writer.write_optional_str(value.get("route").and_then(Value::as_str));
    writer.write_optional_str(value.get("name").and_then(Value::as_str));
    write_optional_json_value(&mut writer, value.get("value"));
    writer.write_optional_str(value.get("error").and_then(Value::as_str));
    Some(writer.finish())
}

fn encode_rpc_invalidated_event(value: &Value) -> Option<Vec<u8>> {
    let mut writer = TypedEventWriter::new(TYPED_RPC_INVALIDATED);
    writer.write_str(value.get("route")?.as_str()?);
    writer.write_optional_str(value.get("name").and_then(Value::as_str));
    writer.write_optional_u64(optional_u64(value.get("rpcId")));
    Some(writer.finish())
}

fn encode_device_event(value: &Value) -> Option<Vec<u8>> {
    let mut writer = TypedEventWriter::new(TYPED_DEVICE_EVENT);
    writer.write_str(value.get("route")?.as_str()?);
    writer.write_str(value.get("event")?.as_str()?);
    Some(writer.finish())
}

fn encode_active_columns_event(value: &Value) -> Option<Vec<u8>> {
    let mut writer = TypedEventWriter::new(TYPED_ACTIVE_COLUMNS);
    let columns = value.get("columns")?.as_array()?;
    writer.write_len(columns.len());
    for column in columns {
        write_column_key(&mut writer, column);
    }
    Some(writer.finish())
}

fn encode_proxy_event(value: &Value) -> Option<Vec<u8>> {
    let mut writer = TypedEventWriter::new(TYPED_PROXY_EVENT);
    writer.write_str(value.get("event")?.as_str()?);
    Some(writer.finish())
}

fn write_available_devices(writer: &mut TypedEventWriter, devices: &[Value]) {
    writer.write_len(devices.len());
    for device in devices {
        writer.write_str(string_field(device, "url"));
        writer.write_str(string_field(device, "label"));
        writer.write_str(string_field(device, "kind"));
        writer.write_str(string_field(device, "detail"));
        let empty_routes = Vec::new();
        let routes = device
            .get("routes")
            .and_then(Value::as_array)
            .unwrap_or(&empty_routes);
        writer.write_len(routes.len());
        for route in routes {
            writer.write_str(string_field(route, "route"));
            writer.write_optional_str(route.get("name").and_then(Value::as_str));
        }
    }
}

fn write_devices(writer: &mut TypedEventWriter, devices: &[Value]) {
    writer.write_len(devices.len());
    for device in devices {
        writer.write_str(string_field(device, "url"));
        writer.write_str(string_field(device, "route"));
        write_device_meta(writer, device.get("meta"));
        write_streams(writer, device.get("streams").and_then(Value::as_array));
        write_rpcs(writer, device.get("rpcs").and_then(Value::as_array));
    }
}

fn write_device_meta(writer: &mut TypedEventWriter, meta: Option<&Value>) {
    let null = Value::Null;
    let meta = meta.unwrap_or(&null);
    writer.write_str(string_field(meta, "serialNumber"));
    writer.write_str(string_field(meta, "firmwareHash"));
    writer.write_u64(u64_field(meta, "nStreams"));
    writer.write_u64(u64_field(meta, "sessionId"));
    writer.write_str(string_field(meta, "name"));
}

fn write_streams(writer: &mut TypedEventWriter, streams: Option<&Vec<Value>>) {
    let empty = Vec::new();
    let streams = streams.unwrap_or(&empty);
    writer.write_len(streams.len());
    for stream in streams {
        writer.write_u8(u64_field(stream, "streamId").min(u8::MAX as u64) as u8);
        writer.write_str(string_field(stream, "name"));
        writer.write_u64(u64_field(stream, "nColumns"));
        writer.write_u64(u64_field(stream, "sampleSize"));
        writer.write_f64(
            stream
                .get("effectiveSamplingRate")
                .and_then(Value::as_f64)
                .unwrap_or(0.0),
        );

        let empty_columns = Vec::new();
        let columns = stream
            .get("columns")
            .and_then(Value::as_array)
            .unwrap_or(&empty_columns);
        writer.write_len(columns.len());
        let null = Value::Null;
        for column in columns {
            write_column_key(writer, column.get("key").unwrap_or(&null));
            writer.write_str(string_field(column, "name"));
            writer.write_str(string_field(column, "units"));
            writer.write_str(string_field(column, "dataType"));
            writer.write_str(string_field(column, "description"));
            writer.write_optional_f64(optional_f64(column.get("displayValue")));
        }
    }
}

fn write_rpcs(writer: &mut TypedEventWriter, rpcs: Option<&Vec<Value>>) {
    let empty = Vec::new();
    let rpcs = rpcs.unwrap_or(&empty);
    writer.write_len(rpcs.len());
    for rpc in rpcs {
        writer.write_str(string_field(rpc, "route"));
        writer.write_str(string_field(rpc, "name"));
        writer.write_u64(u64_field(rpc, "size"));
        writer.write_str(string_field(rpc, "permissions"));
        writer.write_str(string_field(rpc, "argType"));
        writer.write_bool(bool_field(rpc, "readable"));
        writer.write_bool(bool_field(rpc, "writable"));
        writer.write_bool(bool_field(rpc, "persistent"));
        writer.write_bool(bool_field(rpc, "unknown"));
        write_optional_json_value(writer, rpc.get("value"));
    }
}

fn write_column_key(writer: &mut TypedEventWriter, key: &Value) {
    writer.write_str(string_field(key, "route"));
    writer.write_u8(u64_field(key, "streamId").min(u8::MAX as u64) as u8);
    writer.write_i64(i64_field(key, "columnIndex"));
}

fn write_optional_json_value(writer: &mut TypedEventWriter, value: Option<&Value>) {
    let Some(value) = value else {
        writer.write_bool(false);
        return;
    };
    if value.is_null() {
        writer.write_bool(false);
        return;
    }
    writer.write_bool(true);
    write_json_value(writer, value);
}

fn write_json_value(writer: &mut TypedEventWriter, value: &Value) {
    match value {
        Value::Null => writer.write_u8(0),
        Value::Bool(value) => {
            writer.write_u8(1);
            writer.write_bool(*value);
        }
        Value::Number(number) => {
            writer.write_u8(2);
            writer.write_f64(number.as_f64().unwrap_or(0.0));
        }
        Value::String(value) => {
            writer.write_u8(3);
            writer.write_str(value);
        }
        Value::Array(values) => {
            writer.write_u8(4);
            writer.write_len(values.len());
            for value in values {
                write_json_value(writer, value);
            }
        }
        Value::Object(object) => {
            writer.write_u8(5);
            writer.write_len(object.len());
            for (key, value) in object {
                writer.write_str(key);
                write_json_value(writer, value);
            }
        }
    }
}

fn string_field<'a>(value: &'a Value, field: &str) -> &'a str {
    value.get(field).and_then(Value::as_str).unwrap_or("")
}

fn bool_field(value: &Value, field: &str) -> bool {
    value.get(field).and_then(Value::as_bool).unwrap_or(false)
}

fn u64_field(value: &Value, field: &str) -> u64 {
    optional_u64(value.get(field)).unwrap_or(0)
}

fn i64_field(value: &Value, field: &str) -> i64 {
    value
        .get(field)
        .and_then(|value| {
            value
                .as_i64()
                .or_else(|| value.as_u64().map(|value| value as i64))
        })
        .unwrap_or(0)
}

fn optional_u64(value: Option<&Value>) -> Option<u64> {
    value.and_then(|value| {
        if value.is_null() {
            None
        } else {
            value
                .as_u64()
                .or_else(|| value.as_i64().map(|value| value.max(0) as u64))
        }
    })
}

fn optional_f64(value: Option<&Value>) -> Option<f64> {
    value
        .and_then(Value::as_f64)
        .filter(|value| value.is_finite())
}

/// Bumped whenever the per-series layout changes. 5 added the derivation tag
/// after the column index, and the warming-up bit to the flags byte.
const PLOT_FRAME_VERSION: usize = 5;

fn derivation_code(derivation: Option<Derivation>) -> u8 {
    match derivation {
        None => 0,
        Some(Derivation::NoiseFloor) => 1,
    }
}

fn series_flags(item: &BinaryPlotSeries<'_>) -> u8 {
    u8::from(item.outside_window) | (u8::from(item.warming_up) << 1)
}

fn write_plot_payload<W: Write>(
    writer: &mut W,
    pane_id: usize,
    mode: PlotMode,
    viewport_end: Option<f64>,
    series: &[BinaryPlotSeries<'_>],
) -> io::Result<()> {
    write_u8(writer, plot_mode_code(mode))?;
    write_u8(writer, u8::from(viewport_end.is_some()))?;
    write_u16(writer, PLOT_FRAME_VERSION)?;
    write_u32(writer, pane_id)?;
    write_u32(writer, series.len())?;
    write_f64(writer, viewport_end.unwrap_or(0.0))?;

    for item in series {
        let route = item.key.route.as_bytes();
        if route.len() > u16::MAX as usize {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "route is too long for binary plot frame",
            ));
        }
        write_u16(writer, route.len())?;
        writer.write_all(route)?;
        write_u8(writer, item.key.stream_id)?;
        write_u32(writer, item.key.column_index)?;
        write_u8(writer, derivation_code(item.key.derivation))?;
        write_f64(writer, item.sample_rate)?;
        write_u8(writer, series_flags(item))?;
        write_f64(writer, item.noise_floor.unwrap_or(f64::NAN))?;
        write_u32(writer, item.points.len())?;
        item.points.write_to(writer)?;
    }

    Ok(())
}

#[derive(Debug, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum ClientCommand {
    ListDevices {
        include_all: Option<bool>,
    },
    /// Start or stop live device discovery for the connection view. While
    /// active, the bridge pushes a full `deviceList` snapshot whenever the
    /// set of reachable devices changes.
    SetDiscovery {
        active: bool,
        include_all: Option<bool>,
    },
    Connect {
        url: String,
        route: Option<String>,
        log_path: Option<String>,
    },
    SetLogging {
        enabled: bool,
        log_path: Option<String>,
    },
    OpenLog {
        path: String,
    },
    ExportLog {
        request_id: String,
        source_path: String,
        output_path: String,
        format: ExportFormat,
    },
    Disconnect,
    SetPlayback {
        position: f64,
    },
    CopyViewData {
        request_id: String,
        pane_id: Option<usize>,
        viewport_end: Option<f64>,
    },
    SetActiveColumns {
        columns: Vec<ColumnKeyDto>,
    },
    SetPlotPanes {
        panes: Vec<PlotPaneConfig>,
    },
    SetDerivedChannels {
        channels: Vec<DerivedChannelDto>,
    },
    SetView {
        view: ViewConfig,
    },
    CallRpc {
        request_id: String,
        route: String,
        name: String,
        arg: Option<Value>,
    },
    CheckUpgrade,
    PerformUpgrade {
        route: String,
    },
    Shutdown,
}

#[derive(Debug)]
enum SessionCommand {
    Stop,
    SetActiveColumns(Vec<ColumnKeyDto>),
    SetLogging {
        enabled: bool,
        log_path: Option<String>,
    },
    SetView(ViewConfig),
    SetPlotPanes(Vec<PlotPaneConfig>),
    SetDerivedChannels(Vec<DerivedChannelDto>),
    CallRpc {
        request_id: String,
        route: String,
        name: String,
        arg: Option<Value>,
    },
    CopyViewData {
        request_id: String,
        pane_id: Option<usize>,
        viewport_end: Option<f64>,
    },
    CheckUpgrade,
    PerformUpgrade {
        route: String,
    },
}

/// A channel computed from another column rather than received from a device.
///
/// The tag rides on `ColumnKeyDto` so a derived channel is addressable exactly
/// like a raw column — panes, legends, exports and FPCS all keep working
/// unchanged — while clearing the tag recovers the source key. Namespacing by
/// stream id instead would collide with real `u8` ids and lose that link.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "camelCase")]
enum Derivation {
    /// Robust white-noise ASD of the source column's spectrum, sampled over
    /// time. One point per cadence interval, in `source units/sqrt(Hz)`.
    NoiseFloor,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "camelCase")]
struct ColumnKeyDto {
    route: String,
    stream_id: u8,
    column_index: usize,
    /// `None` for a column received from a device.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    derivation: Option<Derivation>,
}

impl ColumnKeyDto {
    fn raw(route: impl Into<String>, stream_id: u8, column_index: usize) -> Self {
        Self {
            route: route.into(),
            stream_id,
            column_index,
            derivation: None,
        }
    }

    fn is_derived(&self) -> bool {
        self.derivation.is_some()
    }

    /// The raw column this key was derived from. Identity for a raw key.
    fn source(&self) -> Self {
        Self {
            derivation: None,
            ..self.clone()
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct ViewConfig {
    mode: PlotMode,
    window_seconds: f64,
    resolution_multiplier: usize,
    plot_width_pixels: usize,
    decimation_method: DecimationMethod,
    detrend: DetrendMethod,
    fft_log_x: bool,
    fft_log_y: bool,
    /// Log vertical axis in timeseries mode. Separate from `fft_log_y` so a
    /// pane toggling between modes keeps each axis choice.
    log_y: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlotPaneConfig {
    id: usize,
    view: ViewConfig,
    columns: Vec<ColumnKeyDto>,
}

impl Default for ViewConfig {
    fn default() -> Self {
        Self {
            mode: PlotMode::Timeseries,
            window_seconds: 10.0,
            resolution_multiplier: 100,
            plot_width_pixels: 800,
            decimation_method: DecimationMethod::Fpcs,
            detrend: DetrendMethod::Quadratic,
            fft_log_x: true,
            fft_log_y: true,
            log_y: false,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
enum PlotMode {
    Timeseries,
    Fft,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
enum DecimationMethod {
    None,
    Fpcs,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
enum DetrendMethod {
    None,
    Mean,
    Linear,
    Quadratic,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
enum ExportFormat {
    Csv,
    Hdf5,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
struct Point {
    x: f64,
    y: f64,
}

#[derive(Debug, Clone)]
struct ViewDataSeries {
    label: String,
    points: Vec<Point>,
}

#[derive(Debug, Clone, Copy)]
struct PlotEmitStats {
    mode: PlotMode,
    series_count: usize,
    point_count: usize,
    viewport_end: Option<f64>,
}

#[derive(Debug, Clone, Copy)]
enum PlotPointSource<'a> {
    Slice(&'a [Point]),
    DequeRange {
        points: &'a VecDeque<Point>,
        start: usize,
        end: usize,
    },
}

impl<'a> PlotPointSource<'a> {
    fn len(&self) -> usize {
        match self {
            Self::Slice(points) => points.len(),
            Self::DequeRange { start, end, .. } => end.saturating_sub(*start),
        }
    }

    fn is_empty(&self) -> bool {
        self.len() == 0
    }

    fn write_to<W: Write>(&self, writer: &mut W) -> io::Result<()> {
        match self {
            Self::Slice(points) => {
                for point in *points {
                    write_point(writer, *point)?;
                }
            }
            Self::DequeRange { points, start, end } => {
                for index in *start..*end {
                    write_point(writer, points[index])?;
                }
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy)]
struct BinaryPlotSeries<'a> {
    key: &'a ColumnKeyDto,
    sample_rate: f64,
    points: PlotPointSource<'a>,
    /// True when this column has data, but none of it falls inside the pane's
    /// displayed time window (its time reference is not compatible with the
    /// pane's anchor stream). The series is sent with no points so the legend
    /// can flag it.
    outside_window: bool,
    /// True for a derived column that exists but has not yet accumulated a
    /// full source window. Distinct from `outside_window`: nothing is wrong,
    /// there is simply no estimate yet, and the legend says so rather than
    /// showing a time-reference warning or silently omitting the trace.
    warming_up: bool,
    /// White-noise ASD estimate for FFT series. Encoded as NaN when absent.
    noise_floor: Option<f64>,
}

fn binary_plot_payload_len(series: &[BinaryPlotSeries<'_>]) -> io::Result<usize> {
    let mut length = 20usize;
    for item in series {
        let route_len = item.key.route.len();
        if route_len > u16::MAX as usize {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "route is too long for binary plot frame",
            ));
        }
        // route len + route + stream id + column index + derivation +
        // sample rate + flags + noise floor + point count
        length = length
            .checked_add(2 + route_len + 1 + 4 + 1 + 8 + 1 + 8 + 4)
            .and_then(|value| value.checked_add(item.points.len().checked_mul(16)?))
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "binary plot frame is too large",
                )
            })?;
    }
    Ok(length)
}

fn plot_mode_code(mode: PlotMode) -> u8 {
    match mode {
        PlotMode::Timeseries => 0,
        PlotMode::Fft => 1,
    }
}

fn write_u8<W: Write>(writer: &mut W, value: u8) -> io::Result<()> {
    writer.write_all(&[value])
}

fn write_u16<W: Write>(writer: &mut W, value: usize) -> io::Result<()> {
    writer.write_all(&(value as u16).to_le_bytes())
}

fn write_u32<W: Write>(writer: &mut W, value: usize) -> io::Result<()> {
    writer.write_all(&(value as u32).to_le_bytes())
}

fn write_f64<W: Write>(writer: &mut W, value: f64) -> io::Result<()> {
    writer.write_all(&value.to_le_bytes())
}

fn write_point<W: Write>(writer: &mut W, point: Point) -> io::Result<()> {
    write_f64(writer, point.x)?;
    write_f64(writer, point.y)
}

struct PlotCadenceProfiler {
    enabled: bool,
    window_start: Instant,
    count: u64,
    total_emit_micros: u128,
    total_points: usize,
    last_viewport_end: Option<f64>,
}

impl PlotCadenceProfiler {
    fn new() -> Self {
        let enabled = profile_env_enabled("TWINLEAF_PLOT_PROFILE");

        Self {
            enabled,
            window_start: Instant::now(),
            count: 0,
            total_emit_micros: 0,
            total_points: 0,
            last_viewport_end: None,
        }
    }

    fn record(&mut self, elapsed: Duration, stats: PlotEmitStats) {
        if !self.enabled {
            return;
        }

        self.count += 1;
        self.total_emit_micros += elapsed.as_micros();
        self.total_points += stats.point_count;
        self.last_viewport_end = stats.viewport_end;

        let window = self.window_start.elapsed();
        if window < Duration::from_secs(1) {
            return;
        }

        let seconds = window.as_secs_f64();
        let rate = self.count as f64 / seconds;
        let avg_emit_ms = self.total_emit_micros as f64 / self.count as f64 / 1_000.0;
        let avg_points = self.total_points as f64 / self.count as f64;
        eprintln!(
            "[tio-bridge] profile plot.emit: {:.1}/s mode={:?} avg_emit={:.2} ms avg_points={:.0} last_series={} last_points={} last_viewport={}",
            rate,
            stats.mode,
            avg_emit_ms,
            avg_points,
            stats.series_count,
            stats.point_count,
            self.last_viewport_end
                .map(|value| format!("{value:.6}"))
                .unwrap_or_else(|| "none".to_string())
        );

        self.window_start = Instant::now();
        self.count = 0;
        self.total_emit_micros = 0;
        self.total_points = 0;
    }
}

fn profile_env_enabled(name: &str) -> bool {
    std::env::var(name)
        .map(|value| matches!(value.to_lowercase().as_str(), "1" | "true" | "yes" | "on"))
        .unwrap_or(false)
}

fn bridge_debug_enabled() -> bool {
    [
        "TWINLEAF_BRIDGE_DEBUG",
        "TWINLEAF_CONSOLE_DEBUG",
        "TWINLEAF_DEBUG_LOGS",
        "TWINLEAF_DEBUG",
    ]
    .iter()
    .any(|name| profile_env_enabled(name))
}

struct StreamIngestProfiler {
    enabled: bool,
    window_start: Instant,
    samples: u64,
    columns: u64,
    active_columns: u64,
    total_process_micros: u128,
    total_display_micros: u128,
    last_states: usize,
    last_active: usize,
}

impl StreamIngestProfiler {
    fn new() -> Self {
        Self {
            enabled: profile_env_enabled("TWINLEAF_STREAM_PROFILE")
                || profile_env_enabled("TWINLEAF_PLOT_PROFILE"),
            window_start: Instant::now(),
            samples: 0,
            columns: 0,
            active_columns: 0,
            total_process_micros: 0,
            total_display_micros: 0,
            last_states: 0,
            last_active: 0,
        }
    }

    fn record(
        &mut self,
        elapsed: Duration,
        display_elapsed: Duration,
        columns: usize,
        active_columns: usize,
        states: usize,
        active: usize,
    ) {
        if !self.enabled {
            return;
        }

        self.samples += 1;
        self.columns += columns as u64;
        self.active_columns += active_columns as u64;
        self.total_process_micros += elapsed.as_micros();
        self.total_display_micros += display_elapsed.as_micros();
        self.last_states = states;
        self.last_active = active;

        let window = self.window_start.elapsed();
        if window < Duration::from_secs(1) {
            return;
        }

        let seconds = window.as_secs_f64();
        let sample_rate = self.samples as f64 / seconds;
        let column_rate = self.columns as f64 / seconds;
        let avg_process_ms = self.total_process_micros as f64 / self.samples as f64 / 1_000.0;
        let avg_display_us = self.total_display_micros as f64 / self.columns.max(1) as f64;
        let avg_columns = self.columns as f64 / self.samples.max(1) as f64;
        eprintln!(
            "[tio-bridge] profile sample.ingest: {:.1} samples/s {:.1} columns/s avg_sample={:.3} ms avg_display={:.2} us avg_columns={:.1} active_hits={} states={} active={}",
            sample_rate,
            column_rate,
            avg_process_ms,
            avg_display_us,
            avg_columns,
            self.active_columns,
            self.last_states,
            self.last_active
        );

        self.window_start = Instant::now();
        self.samples = 0;
        self.columns = 0;
        self.active_columns = 0;
        self.total_process_micros = 0;
        self.total_display_micros = 0;
    }
}

struct StreamValueEmitProfiler {
    enabled: bool,
    window_start: Instant,
    count: u64,
    total_emit_micros: u128,
    total_values: usize,
    last_values: usize,
    last_states: usize,
}

impl StreamValueEmitProfiler {
    fn new() -> Self {
        Self {
            enabled: profile_env_enabled("TWINLEAF_STREAM_PROFILE")
                || profile_env_enabled("TWINLEAF_PLOT_PROFILE"),
            window_start: Instant::now(),
            count: 0,
            total_emit_micros: 0,
            total_values: 0,
            last_values: 0,
            last_states: 0,
        }
    }

    fn record(&mut self, elapsed: Duration, values: usize, states: usize) {
        if !self.enabled {
            return;
        }

        self.count += 1;
        self.total_emit_micros += elapsed.as_micros();
        self.total_values += values;
        self.last_values = values;
        self.last_states = states;

        let window = self.window_start.elapsed();
        if window < Duration::from_secs(1) {
            return;
        }

        let seconds = window.as_secs_f64();
        let rate = self.count as f64 / seconds;
        let avg_emit_ms = self.total_emit_micros as f64 / self.count as f64 / 1_000.0;
        let avg_values = self.total_values as f64 / self.count.max(1) as f64;
        eprintln!(
            "[tio-bridge] profile streamValues.emit: {:.1}/s avg_emit={:.3} ms avg_values={:.1} last_values={} states={}",
            rate, avg_emit_ms, avg_values, self.last_values, self.last_states
        );

        self.window_start = Instant::now();
        self.count = 0;
        self.total_emit_micros = 0;
        self.total_values = 0;
    }
}

#[derive(Default)]
struct SessionLoopProfile {
    status_elapsed: Duration,
    command_elapsed: Duration,
    raw_log_elapsed: Duration,
    drain_elapsed: Duration,
    process_elapsed: Duration,
    event_elapsed: Duration,
    plot_elapsed: Duration,
    stream_value_elapsed: Duration,
    flush_elapsed: Duration,
    busy_elapsed: Duration,
    status_events: usize,
    commands: usize,
    raw_packets: usize,
    samples: usize,
    device_events: usize,
    plot_emits: usize,
    stream_values: usize,
    flushes: usize,
}

struct SessionLoopProfiler {
    enabled: bool,
    window_start: Instant,
    iterations: u64,
    total_busy_micros: u128,
    max_busy_micros: u128,
    total_status_micros: u128,
    total_command_micros: u128,
    total_raw_log_micros: u128,
    total_drain_micros: u128,
    total_process_micros: u128,
    total_event_micros: u128,
    total_plot_micros: u128,
    total_stream_value_micros: u128,
    total_flush_micros: u128,
    status_events: usize,
    commands: usize,
    raw_packets: usize,
    samples: usize,
    device_events: usize,
    plot_emits: usize,
    stream_values: usize,
    flushes: usize,
    last_states: usize,
    last_active: usize,
    last_retained_points: usize,
}

impl SessionLoopProfiler {
    fn new() -> Self {
        Self {
            enabled: profile_env_enabled("TWINLEAF_LOOP_PROFILE")
                || profile_env_enabled("TWINLEAF_STREAM_PROFILE")
                || profile_env_enabled("TWINLEAF_PLOT_PROFILE"),
            window_start: Instant::now(),
            iterations: 0,
            total_busy_micros: 0,
            max_busy_micros: 0,
            total_status_micros: 0,
            total_command_micros: 0,
            total_raw_log_micros: 0,
            total_drain_micros: 0,
            total_process_micros: 0,
            total_event_micros: 0,
            total_plot_micros: 0,
            total_stream_value_micros: 0,
            total_flush_micros: 0,
            status_events: 0,
            commands: 0,
            raw_packets: 0,
            samples: 0,
            device_events: 0,
            plot_emits: 0,
            stream_values: 0,
            flushes: 0,
            last_states: 0,
            last_active: 0,
            last_retained_points: 0,
        }
    }

    fn record(
        &mut self,
        sample: SessionLoopProfile,
        states: usize,
        active: usize,
        retained_points: usize,
    ) {
        if !self.enabled {
            return;
        }

        self.iterations += 1;
        self.total_busy_micros += sample.busy_elapsed.as_micros();
        self.max_busy_micros = self.max_busy_micros.max(sample.busy_elapsed.as_micros());
        self.total_status_micros += sample.status_elapsed.as_micros();
        self.total_command_micros += sample.command_elapsed.as_micros();
        self.total_raw_log_micros += sample.raw_log_elapsed.as_micros();
        self.total_drain_micros += sample.drain_elapsed.as_micros();
        self.total_process_micros += sample.process_elapsed.as_micros();
        self.total_event_micros += sample.event_elapsed.as_micros();
        self.total_plot_micros += sample.plot_elapsed.as_micros();
        self.total_stream_value_micros += sample.stream_value_elapsed.as_micros();
        self.total_flush_micros += sample.flush_elapsed.as_micros();
        self.status_events += sample.status_events;
        self.commands += sample.commands;
        self.raw_packets += sample.raw_packets;
        self.samples += sample.samples;
        self.device_events += sample.device_events;
        self.plot_emits += sample.plot_emits;
        self.stream_values += sample.stream_values;
        self.flushes += sample.flushes;
        self.last_states = states;
        self.last_active = active;
        self.last_retained_points = retained_points;

        let window = self.window_start.elapsed();
        if window < Duration::from_secs(1) {
            return;
        }

        let seconds = window.as_secs_f64();
        let loops_per_second = self.iterations as f64 / seconds;
        let divisor = self.iterations.max(1) as f64;
        let avg_ms = |micros: u128| micros as f64 / divisor / 1_000.0;
        eprintln!(
            "[tio-bridge] profile session.loop: {:.1}/s busy={:.3} ms max_busy={:.3} ms status={:.3} command={:.3} raw={:.3} drain={:.3} process={:.3} events={:.3} plot={:.3} values={:.3} flush={:.3} samples/s={:.1} raw_packets/s={:.1} plots={} value_updates={} states={} active={} retained_points={}",
            loops_per_second,
            avg_ms(self.total_busy_micros),
            self.max_busy_micros as f64 / 1_000.0,
            avg_ms(self.total_status_micros),
            avg_ms(self.total_command_micros),
            avg_ms(self.total_raw_log_micros),
            avg_ms(self.total_drain_micros),
            avg_ms(self.total_process_micros),
            avg_ms(self.total_event_micros),
            avg_ms(self.total_plot_micros),
            avg_ms(self.total_stream_value_micros),
            avg_ms(self.total_flush_micros),
            self.samples as f64 / seconds,
            self.raw_packets as f64 / seconds,
            self.plot_emits,
            self.stream_values,
            self.last_states,
            self.last_active,
            self.last_retained_points
        );

        *self = Self {
            enabled: self.enabled,
            window_start: Instant::now(),
            ..Self::new()
        };
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct AvailableDevice {
    url: String,
    label: String,
    kind: String,
    detail: String,
    routes: Vec<AvailableRoute>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct AvailableRoute {
    route: String,
    name: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct DeviceDto {
    url: String,
    route: String,
    meta: DeviceMetaDto,
    streams: Vec<StreamDto>,
    rpcs: Vec<RpcDto>,
    #[serde(skip_serializing)]
    full_metadata: Option<DeviceMetadataSnapshot>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct DeviceMetaDto {
    serial_number: String,
    firmware_hash: String,
    n_streams: usize,
    session_id: u32,
    name: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct StreamDto {
    stream_id: u8,
    name: String,
    n_columns: usize,
    sample_size: usize,
    effective_sampling_rate: f64,
    columns: Vec<ColumnDto>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct ColumnDto {
    key: ColumnKeyDto,
    name: String,
    units: String,
    data_type: String,
    description: String,
    display_value: Option<f64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct RpcDto {
    route: String,
    name: String,
    size: usize,
    permissions: String,
    arg_type: String,
    readable: bool,
    writable: bool,
    persistent: bool,
    unknown: bool,
    value: Option<Value>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct PlotSeries {
    key: ColumnKeyDto,
    label: String,
    units: String,
    sample_rate: f64,
    points: Vec<Point>,
    noise_floor: Option<f64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct StreamValueDto {
    key: ColumnKeyDto,
    value: f64,
}

#[derive(Debug)]
struct FftSeriesInput {
    key: ColumnKeyDto,
    label: String,
    units: String,
    sample_rate: f64,
    points: Vec<Point>,
}

#[derive(Debug)]
struct FftRequest {
    generation: u64,
    viewport_end: Option<f64>,
    window_seconds: f64,
    detrend: DetrendMethod,
    target_points: usize,
    inputs: Vec<FftSeriesInput>,
}

#[derive(Debug, Clone)]
struct FftResult {
    generation: u64,
    viewport_end: Option<f64>,
    window_seconds: f64,
    series: Vec<PlotSeries>,
}

struct FftWorker {
    request_tx: Sender<FftRequest>,
    result_rx: Receiver<FftResult>,
    generation: u64,
    in_flight: bool,
    latest: Option<FftResult>,
    latest_emitted: bool,
    needs_clear_emit: bool,
    last_request_at: Option<Instant>,
}

impl FftWorker {
    fn new(emitter: &Emitter) -> Self {
        let (request_tx, request_rx) = channel::bounded::<FftRequest>(1);
        let (result_tx, result_rx) = channel::unbounded::<FftResult>();
        let worker_emitter = emitter.clone();

        thread::Builder::new()
            .name("fft-worker".into())
            .spawn(move || {
                while let Ok(request) = request_rx.recv() {
                    let started = Instant::now();
                    let result = calculate_fft_request(request);
                    worker_emitter.debug(format!(
                        "FFT worker completed generation {} with {} series in {:.1} ms",
                        result.generation,
                        result.series.len(),
                        started.elapsed().as_secs_f64() * 1_000.0
                    ));
                    if result_tx.send(result).is_err() {
                        break;
                    }
                }
            })
            .expect("failed to spawn FFT worker");

        Self {
            request_tx,
            result_rx,
            generation: 0,
            in_flight: false,
            latest: None,
            latest_emitted: true,
            needs_clear_emit: false,
            last_request_at: None,
        }
    }

    fn poll(&mut self) {
        while let Ok(result) = self.result_rx.try_recv() {
            self.in_flight = false;
            if result.generation == self.generation {
                self.latest = Some(result);
                self.latest_emitted = false;
                self.needs_clear_emit = false;
            }
        }
    }

    fn is_ready_for_request(&mut self) -> bool {
        self.poll();

        if self.in_flight {
            return false;
        }

        if let Some(last_request_at) = self.last_request_at {
            if last_request_at.elapsed() < Duration::from_millis(66) {
                return false;
            }
        }

        true
    }

    fn submit_request(&mut self, request: FftRequest, emitter: &Emitter) {
        if request.inputs.is_empty() {
            self.latest = Some(FftResult {
                generation: self.generation,
                viewport_end: request.viewport_end,
                window_seconds: request.window_seconds,
                series: Vec::new(),
            });
            self.latest_emitted = false;
            self.needs_clear_emit = false;
            return;
        }

        match self.request_tx.try_send(request) {
            Ok(()) => {
                self.in_flight = true;
                self.last_request_at = Some(Instant::now());
            }
            Err(channel::TrySendError::Full(_)) => {
                self.in_flight = true;
            }
            Err(channel::TrySendError::Disconnected(_)) => {
                emitter.error("FFT worker stopped unexpectedly");
            }
        }
    }

    fn take_pending_emit(
        &mut self,
        viewport_end: Option<f64>,
        window_seconds: f64,
    ) -> Option<FftResult> {
        self.poll();

        if self.needs_clear_emit {
            self.needs_clear_emit = false;
            return Some(FftResult {
                generation: self.generation,
                viewport_end,
                window_seconds,
                series: Vec::new(),
            });
        }

        let result = self
            .latest
            .as_ref()
            .filter(|result| result.generation == self.generation)?
            .clone();
        if !same_fft_window_seconds(result.window_seconds, window_seconds) {
            return None;
        }
        if self.latest_emitted {
            return None;
        }

        self.latest_emitted = true;
        Some(result)
    }
}

fn same_fft_window_seconds(lhs: f64, rhs: f64) -> bool {
    let scale = lhs.abs().max(rhs.abs()).max(1.0);
    (lhs - rhs).abs() <= scale * 1e-9
}

/// How a derived channel is produced. Parameters live here rather than in the
/// key so that retuning a channel re-derives it in place instead of
/// invalidating every pane selection and saved layout that referenced it.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct DerivedChannelDto {
    /// Source column key with `derivation` applied.
    key: ColumnKeyDto,
    /// Seconds of source data behind each estimate.
    window_seconds: f64,
    /// Seconds between emitted points.
    cadence_seconds: f64,
    detrend: DetrendMethod,
}

impl DerivedChannelDto {
    fn source(&self) -> ColumnKeyDto {
        self.key.source()
    }

    fn kind(&self) -> Option<Derivation> {
        self.key.derivation
    }

    /// Derived units for a source measured in `units`.
    fn units(&self, units: &str) -> String {
        match self.kind() {
            Some(Derivation::NoiseFloor) if units.is_empty() => "1/sqrt(Hz)".to_string(),
            Some(Derivation::NoiseFloor) => format!("{units}/sqrt(Hz)"),
            None => units.to_string(),
        }
    }
}

#[derive(Debug)]
struct DerivedJob {
    key: ColumnKeyDto,
    /// Timestamp to stamp the result with: the end of the window the estimate
    /// was taken over, matching what an FFT pane's legend reads at that
    /// instant.
    x: f64,
    sample_rate: f64,
    detrend: DetrendMethod,
    points: Vec<Point>,
}

#[derive(Debug)]
struct DerivedOutcome {
    key: ColumnKeyDto,
    x: f64,
    /// `None` when the window was too short or too contaminated to yield an
    /// estimate; the tick is skipped rather than plotted as a gap value.
    y: Option<f64>,
}

/// Computes derived-channel points off the ingest thread.
///
/// Deliberately separate from `FftWorker`: that one is bound to per-pane
/// display generations and viewport semantics, and folding derivation into it
/// would couple a background summary to what happens to be on screen.
struct DerivedWorker {
    request_tx: Sender<Vec<DerivedJob>>,
    result_rx: Receiver<Vec<DerivedOutcome>>,
    in_flight: bool,
}

impl DerivedWorker {
    fn new() -> Self {
        let (request_tx, request_rx) = channel::bounded::<Vec<DerivedJob>>(1);
        let (result_tx, result_rx) = channel::unbounded::<Vec<DerivedOutcome>>();

        thread::Builder::new()
            .name("derived-worker".into())
            .spawn(move || {
                while let Ok(jobs) = request_rx.recv() {
                    let outcomes: Vec<DerivedOutcome> =
                        jobs.into_iter().map(run_derived_job).collect();
                    if result_tx.send(outcomes).is_err() {
                        break;
                    }
                }
            })
            .expect("failed to spawn derived channel worker");

        Self {
            request_tx,
            result_rx,
            in_flight: false,
        }
    }

    fn take_results(&mut self) -> Vec<DerivedOutcome> {
        let mut outcomes = Vec::new();
        while let Ok(batch) = self.result_rx.try_recv() {
            self.in_flight = false;
            outcomes.extend(batch);
        }
        outcomes
    }

    /// Drops the batch when one is already running. A derived channel is a
    /// coarse summary, so a skipped tick costs nothing — and the points carry
    /// their own timestamps, so the trace stays truthful either way.
    fn submit(&mut self, jobs: Vec<DerivedJob>) {
        if self.in_flight || jobs.is_empty() {
            return;
        }
        match self.request_tx.try_send(jobs) {
            Ok(()) => self.in_flight = true,
            Err(channel::TrySendError::Full(_)) => self.in_flight = true,
            Err(channel::TrySendError::Disconnected(_)) => {}
        }
    }
}

fn run_derived_job(job: DerivedJob) -> DerivedOutcome {
    let y = match job.key.derivation {
        Some(Derivation::NoiseFloor) => {
            let spectrum = fft_points(&job.points, job.sample_rate, job.detrend);
            estimate_white_noise_floor(&spectrum)
        }
        None => None,
    };
    DerivedOutcome {
        key: job.key,
        x: job.x,
        y,
    }
}

#[derive(Debug, Clone)]
struct ColumnState {
    label: String,
    units: String,
    sample_rate: f64,
    raw: VecDeque<Point>,
    fpcs_by_pane: HashMap<usize, StreamingFpcs>,
    display_value: Option<f64>,
    display_value_x: Option<f64>,
}

impl ColumnState {
    fn new(label: String, units: String, sample_rate: f64) -> Self {
        Self {
            label,
            units,
            sample_rate,
            raw: VecDeque::new(),
            fpcs_by_pane: HashMap::new(),
            display_value: None,
            display_value_x: None,
        }
    }

    #[cfg(test)]
    fn push_raw(&mut self, point: Point, max_window_seconds: f64) {
        let _ = self.push_raw_profiled(point, max_window_seconds, false);
    }

    fn push_raw_profiled(
        &mut self,
        point: Point,
        max_window_seconds: f64,
        profile_display: bool,
    ) -> Duration {
        self.raw.push_back(point);
        let display_start = profile_display.then(Instant::now);
        self.update_display_value(point);
        let display_elapsed = display_start
            .map(|start| start.elapsed())
            .unwrap_or(Duration::ZERO);
        while let Some(front) = self.raw.front() {
            if point.x - front.x > max_window_seconds {
                self.raw.pop_front();
            } else {
                break;
            }
        }
        // Hard cap so a long window combined with a fast sample rate can't
        // grow the per-stream buffer without bound. Trims the oldest points
        // first — same direction as the time-based prune above.
        while self.raw.len() > MAX_RAW_POINTS_PER_STREAM {
            self.raw.pop_front();
        }
        display_elapsed
    }

    fn recent_points(&self, window_seconds: f64) -> Vec<Point> {
        let Some(last) = self.raw.back() else {
            return Vec::new();
        };
        let start = last.x - window_seconds;
        self.points_between(start, last.x)
    }

    fn fft_window_points(&self, window_seconds: f64, viewport_end: Option<f64>) -> Vec<Point> {
        let sample_count = self.fft_window_sample_count(window_seconds);
        let end_index = viewport_end
            .map(|end| self.upper_bound_x(end))
            .unwrap_or(self.raw.len());
        self.sample_window_ending_at_index(end_index, sample_count)
    }

    fn fft_window_sample_count(&self, window_seconds: f64) -> usize {
        if !window_seconds.is_finite() || !self.sample_rate.is_finite() || self.sample_rate <= 0.0 {
            return 0;
        }

        (window_seconds.max(1e-6) * self.sample_rate)
            .ceil()
            .max(1.0) as usize
    }

    fn sample_window_ending_at_index(&self, end_index: usize, sample_count: usize) -> Vec<Point> {
        if self.raw.is_empty() || sample_count == 0 || end_index == 0 {
            return Vec::new();
        }

        let end_index = end_index.min(self.raw.len());
        let start_index = end_index.saturating_sub(sample_count);
        (start_index..end_index)
            .map(|index| self.raw[index])
            .collect()
    }

    fn points_between(&self, start: f64, end: f64) -> Vec<Point> {
        if self.raw.is_empty() || start > end {
            return Vec::new();
        }

        let start_index = self.lower_bound_x(start);
        let end_index = self.upper_bound_x(end);
        if start_index >= end_index {
            return Vec::new();
        }

        (start_index..end_index)
            .map(|index| self.raw[index])
            .collect()
    }

    fn point_source_between(&self, start: f64, end: f64) -> PlotPointSource<'_> {
        if self.raw.is_empty() || start > end {
            return PlotPointSource::DequeRange {
                points: &self.raw,
                start: 0,
                end: 0,
            };
        }

        let start_index = self.lower_bound_x(start);
        let end_index = self.upper_bound_x(end);
        PlotPointSource::DequeRange {
            points: &self.raw,
            start: start_index,
            end: end_index.max(start_index),
        }
    }

    fn lower_bound_x(&self, target: f64) -> usize {
        lower_bound_point_deque(&self.raw, target)
    }

    fn upper_bound_x(&self, target: f64) -> usize {
        upper_bound_point_deque(&self.raw, target)
    }

    fn ensure_fpcs_configured(&mut self, pane_id: usize, view: &ViewConfig) {
        let ratio = fpcs_ratio(self.sample_rate, view);
        let capacity = target_plot_points(view).max(2);
        if self
            .fpcs_by_pane
            .get(&pane_id)
            .is_some_and(|fpcs| fpcs.ratio == ratio && fpcs.capacity == capacity)
        {
            return;
        }
        self.rebuild_fpcs(pane_id, view);
    }

    /// Rebuild the pane's FPCS decimator from the retained raw buffer,
    /// discarding any existing ring. The raw buffer is filled for every column
    /// regardless of selection, so rebuilding here keeps the decimated trace
    /// continuous when a column re-enters a pane. Without it, the ring frozen
    /// while the column was unselected would be stitched onto fresh points,
    /// leaving a gap across the unselected interval.
    fn rebuild_fpcs(&mut self, pane_id: usize, view: &ViewConfig) {
        let ratio = fpcs_ratio(self.sample_rate, view);
        let capacity = target_plot_points(view).max(2);
        let mut fpcs = StreamingFpcs::new(ratio, capacity);
        for point in self.recent_points(view.window_seconds) {
            fpcs.process_point(point);
        }
        self.fpcs_by_pane.insert(pane_id, fpcs);
    }

    fn process_fpcs_point(&mut self, pane_id: usize, view: &ViewConfig, point: Point) {
        self.ensure_fpcs_configured(pane_id, view);
        if let Some(fpcs) = self.fpcs_by_pane.get_mut(&pane_id) {
            fpcs.process_point(point);
        }
    }

    fn fpcs_for_pane(&self, pane_id: usize) -> Option<&StreamingFpcs> {
        self.fpcs_by_pane.get(&pane_id)
    }

    fn retain_fpcs_panes(&mut self, pane_ids: &HashSet<usize>) {
        self.fpcs_by_pane
            .retain(|pane_id, _| pane_ids.contains(pane_id));
    }

    fn update_display_value(&mut self, point: Point) {
        update_smoothed_display_value(&mut self.display_value, &mut self.display_value_x, point);
    }

    fn display_value_between(&self, start: f64, end: f64) -> Option<f64> {
        if self.raw.is_empty() || start > end {
            return None;
        }

        let start_index = self.lower_bound_x(start);
        let end_index = self.upper_bound_x(end);
        if start_index >= end_index {
            return None;
        }

        let mut display_value = None;
        let mut display_value_x = None;
        for index in start_index..end_index {
            update_smoothed_display_value(
                &mut display_value,
                &mut display_value_x,
                self.raw[index],
            );
        }
        display_value
    }
}

fn update_smoothed_display_value(
    display_value: &mut Option<f64>,
    display_value_x: &mut Option<f64>,
    point: Point,
) {
    // Never let a non-finite sample into the smoothing state: a single NaN would
    // poison every subsequent value, because `NaN + alpha * (y - NaN)` stays NaN
    // forever. Non-finite samples are simply skipped.
    if !point.y.is_finite() {
        return;
    }

    // Treat a missing — or, defensively, a non-finite — prior state as "no
    // state", so the first good value after a NaN run passes straight through
    // and the average resumes from there instead of staying poisoned. Guarding
    // the prior timestamp too keeps a bad `dt` from producing a NaN `alpha`.
    let previous = display_value.filter(|value| value.is_finite());
    let previous_x = display_value_x.filter(|x| x.is_finite());

    let alpha = match (previous, previous_x) {
        (Some(_), Some(previous_x)) => {
            let dt = (point.x - previous_x).max(0.0);
            (1.0 - (-dt / 0.25).exp()).clamp(0.02, 1.0)
        }
        _ => 1.0,
    };

    *display_value = Some(match previous {
        Some(previous) => previous + alpha * (point.y - previous),
        None => point.y,
    });
    *display_value_x = point.x.is_finite().then_some(point.x);
}

fn lower_bound_point_deque(points: &VecDeque<Point>, target: f64) -> usize {
    let mut low = 0;
    let mut high = points.len();
    while low < high {
        let mid = low + (high - low) / 2;
        if points[mid].x < target {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    low
}

fn upper_bound_point_deque(points: &VecDeque<Point>, target: f64) -> usize {
    let mut low = 0;
    let mut high = points.len();
    while low < high {
        let mid = low + (high - low) / 2;
        if points[mid].x <= target {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    low
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FpcsLastRetained {
    None,
    Max,
    Min,
}

#[derive(Debug, Clone)]
struct StreamingFpcs {
    ratio: usize,
    capacity: usize,
    output: VecDeque<Point>,
    counter: usize,
    potential_point: Option<Point>,
    last_retained_flag: FpcsLastRetained,
    window_max_point: Option<Point>,
    window_min_point: Option<Point>,
}

impl StreamingFpcs {
    fn new(ratio: usize, capacity: usize) -> Self {
        Self {
            ratio: ratio.max(1),
            capacity: capacity.max(2),
            output: VecDeque::new(),
            counter: 0,
            potential_point: None,
            last_retained_flag: FpcsLastRetained::None,
            window_max_point: None,
            window_min_point: None,
        }
    }

    fn retain_point(&mut self, point: Point) {
        while self.output.len() >= self.capacity {
            self.output.pop_front();
        }
        self.output.push_back(point);
    }

    fn process_point(&mut self, point: Point) {
        if self.window_max_point.is_none() {
            self.retain_point(point);
            self.window_max_point = Some(point);
            self.window_min_point = Some(point);
            self.counter = 1;
            return;
        }

        let mut max_point = self.window_max_point.unwrap();
        let mut min_point = self.window_min_point.unwrap();

        self.counter += 1;

        if point.y >= max_point.y {
            max_point = point;
        } else if point.y < min_point.y {
            min_point = point;
        }

        if self.counter >= self.ratio {
            if min_point.x < max_point.x {
                if self.last_retained_flag == FpcsLastRetained::Min
                    && self.potential_point != Some(min_point)
                {
                    if let Some(potential) = self.potential_point {
                        self.retain_point(potential);
                    }
                }
                self.retain_point(min_point);
                self.potential_point = Some(max_point);
                min_point = max_point;
                self.last_retained_flag = FpcsLastRetained::Min;
            } else {
                if self.last_retained_flag == FpcsLastRetained::Max
                    && self.potential_point != Some(max_point)
                {
                    if let Some(potential) = self.potential_point {
                        self.retain_point(potential);
                    }
                }
                self.retain_point(max_point);
                self.potential_point = Some(min_point);
                max_point = min_point;
                self.last_retained_flag = FpcsLastRetained::Max;
            }
            self.counter = 0;
        }

        self.window_max_point = Some(max_point);
        self.window_min_point = Some(min_point);
    }

    fn points_since(&self, start: f64) -> Vec<Point> {
        self.output
            .iter()
            .copied()
            .filter(|point| point.x >= start)
            .collect()
    }

    fn point_source_since(&self, start: f64) -> PlotPointSource<'_> {
        let start_index = lower_bound_point_deque(&self.output, start);
        PlotPointSource::DequeRange {
            points: &self.output,
            start: start_index,
            end: self.output.len(),
        }
    }
}

struct PacketLogger {
    writer: Option<BufWriter<File>>,
    path: Option<String>,
    packets_written: u64,
    bytes_written: u64,
    serialize_errors: u64,
}

impl PacketLogger {
    fn new(log_path: Option<String>, emitter: &Emitter) -> Self {
        let mut logger = Self {
            writer: None,
            path: None,
            packets_written: 0,
            bytes_written: 0,
            serialize_errors: 0,
        };
        if let Some(path) = log_path {
            logger.open(path, emitter);
        }
        logger
    }

    fn set_enabled(
        &mut self,
        enabled: bool,
        log_path: Option<String>,
        devices: &[DeviceDto],
        emitter: &Emitter,
    ) {
        if enabled {
            let Some(path) = log_path else {
                emitter.error("No log file path provided for logging");
                return;
            };
            if self.open(path, emitter) {
                self.write_startup_metadata(devices, emitter);
            }
        } else {
            self.disable(emitter);
        }
    }

    fn open(&mut self, path: String, emitter: &Emitter) -> bool {
        self.flush();
        match OpenOptions::new().create(true).append(true).open(&path) {
            Ok(file) => {
                emitter.status("logging", format!("Writing Twinleaf packets to {path}"));
                self.writer = Some(BufWriter::new(file));
                self.path = Some(path);
                self.packets_written = 0;
                self.bytes_written = 0;
                self.serialize_errors = 0;
                true
            }
            Err(err) => {
                emitter.error(format!("Failed to open log file: {err}"));
                false
            }
        }
    }

    fn disable(&mut self, emitter: &Emitter) {
        if !self.is_enabled() && self.path.is_none() {
            return;
        }
        self.flush();
        self.writer = None;
        self.path = None;
        self.packets_written = 0;
        self.bytes_written = 0;
        self.serialize_errors = 0;
        emitter.status("streaming", "Streaming without recording");
    }

    fn is_enabled(&self) -> bool {
        self.writer.is_some()
    }

    fn write_packet(&mut self, packet: tio::Packet, emitter: &Emitter) {
        let Some(writer) = self.writer.as_mut() else {
            return;
        };
        match packet.serialize() {
            Ok(raw) => {
                if writer.write_all(&raw).is_ok() {
                    let _ = writer.flush();
                    self.packets_written += 1;
                    self.bytes_written += raw.len() as u64;
                }
            }
            Err(err) => {
                self.serialize_errors += 1;
                if self.serialize_errors <= 3 {
                    emitter.error(format!(
                        "Failed to serialize packet for log: route={}, payload={}: {err:?}",
                        packet.routing,
                        payload_name(&packet.payload)
                    ));
                }
            }
        }
    }

    fn write_startup_metadata(&mut self, devices: &[DeviceDto], emitter: &Emitter) {
        if !self.is_enabled() {
            return;
        }

        let mut metadata_packets = 0usize;
        for device in devices {
            let Some(metadata) = &device.full_metadata else {
                emitter.debug(format!(
                    "startup log metadata unavailable for route {}",
                    device.route
                ));
                continue;
            };
            let route = match DeviceRoute::from_str(&device.route) {
                Ok(route) => route,
                Err(err) => {
                    emitter.error(format!(
                        "Failed to parse startup metadata route {}: {err:?}",
                        device.route
                    ));
                    continue;
                }
            };

            metadata_packets += self.write_metadata_packets(&route, metadata, emitter);
        }

        if metadata_packets > 0 {
            self.flush();
            emitter.debug(format!(
                "wrote {metadata_packets} startup metadata packet(s) to log"
            ));
        }
    }

    fn write_metadata_packets(
        &mut self,
        route: &DeviceRoute,
        metadata: &DeviceMetadataSnapshot,
        emitter: &Emitter,
    ) -> usize {
        let before = self.packets_written;
        self.write_packet(
            metadata.device.make_update_with_route(route.clone()),
            emitter,
        );

        let mut stream_ids: Vec<u8> = metadata.streams.keys().copied().collect();
        stream_ids.sort_unstable();
        for stream_id in stream_ids {
            let Some(stream) = metadata.streams.get(&stream_id) else {
                continue;
            };
            self.write_packet(stream.stream.make_update_with_route(route.clone()), emitter);
            self.write_packet(
                stream.segment.make_update_with_route(route.clone()),
                emitter,
            );

            let mut columns = stream.columns.clone();
            columns.sort_by_key(|column| column.index);
            for column in columns {
                self.write_packet(column.make_update_with_route(route.clone()), emitter);
            }
        }

        (self.packets_written - before) as usize
    }

    fn flush(&mut self) {
        if let Some(writer) = self.writer.as_mut() {
            let _ = writer.flush();
        }
    }

    fn emit_progress(
        &self,
        emitter: &Emitter,
        start_seconds: Option<f64>,
        end_seconds: Option<f64>,
        time_reference_start: Option<f64>,
    ) {
        if !self.is_enabled() {
            return;
        }
        let elapsed_seconds = start_seconds
            .zip(end_seconds)
            .map(|(start, end)| (end - start).max(0.0));
        let file_bytes = self
            .path
            .as_ref()
            .and_then(|path| std::fs::metadata(path).ok())
            .map(|metadata| metadata.len())
            .unwrap_or(self.bytes_written);

        emitter.emit(&json!({
            "type": "logProgress",
            "path": self.path,
            "packets": self.packets_written,
            "bytes": self.bytes_written,
            "fileBytes": file_bytes,
            "startSeconds": start_seconds,
            "endSeconds": end_seconds,
            "elapsedSeconds": elapsed_seconds,
            "timeReferenceStart": time_reference_start,
            "serializeErrors": self.serialize_errors
        }));
    }
}

struct PlaybackSession {
    devices: Vec<DeviceDto>,
    column_states: HashMap<ColumnKeyDto, ColumnState>,
    active_columns: HashSet<ColumnKeyDto>,
    view: ViewConfig,
    plot_panes: Vec<PlotPaneConfig>,
    derived_channels: Vec<DerivedChannelDto>,
    range: Option<(f64, f64)>,
    recording_start: Option<f64>,
    time_reference_start: Option<f64>,
    position: f64,
}

impl PlaybackSession {
    fn new(
        devices: Vec<DeviceDto>,
        column_states: HashMap<ColumnKeyDto, ColumnState>,
        recording_start: Option<f64>,
        time_reference_start: Option<f64>,
    ) -> Self {
        let range = data_range(&column_states);
        let position = range.map(|(_, end)| end).unwrap_or(0.0);
        let view = ViewConfig::default();
        Self {
            devices,
            column_states,
            active_columns: HashSet::new(),
            plot_panes: default_plot_panes(&view),
            derived_channels: Vec::new(),
            view,
            range,
            recording_start,
            time_reference_start,
            position,
        }
    }

    fn set_position(&mut self, position: f64) {
        self.position = self.clamp_position(position);
    }

    fn set_active_columns(&mut self, columns: Vec<ColumnKeyDto>) {
        update_default_pane_columns(&mut self.plot_panes, columns, &self.view);
        self.active_columns = active_columns_for_panes(&self.plot_panes);
    }

    fn set_view(&mut self, view: ViewConfig) {
        self.view = view;
        apply_view_to_all_panes(&mut self.plot_panes, &self.view);
        self.active_columns = active_columns_for_panes(&self.plot_panes);
        self.position = self.clamp_position(self.position);
    }

    fn set_plot_panes(&mut self, panes: Vec<PlotPaneConfig>) {
        self.plot_panes = panes;
        self.active_columns = active_columns_for_panes(&self.plot_panes);
        self.position = self.clamp_position(self.position);
    }

    /// A log holds raw samples only, so derived channels are recomputed from
    /// it. Deriving the whole range up front means every later operation —
    /// scrubbing, export, plotting — sees a derived column that behaves
    /// exactly like a recorded one.
    fn set_derived_channels(&mut self, channels: Vec<DerivedChannelDto>) {
        self.column_states.retain(|key, _| !key.is_derived());
        rebuild_derived_columns_for_range(&channels, &mut self.column_states, self.range);
        self.derived_channels = channels;
        self.active_columns = active_columns_for_panes(&self.plot_panes);
    }

    fn clamp_position(&self, position: f64) -> f64 {
        let Some((start, end)) = self.range else {
            return 0.0;
        };
        let window = self
            .plot_panes
            .iter()
            .map(|pane| pane.view.window_seconds)
            .fold(self.view.window_seconds, f64::max)
            .max(1e-6);
        let min_position = (start + window).min(end);
        position.clamp(min_position, end)
    }

    fn emit_state(&self, emitter: &Emitter) {
        let (start, end) = self.range.unwrap_or((0.0, 0.0));
        emitter.emit(&json!({
            "type": "playback",
            "start": start,
            "end": end,
            "position": self.position,
            "recordingStart": self.recording_start,
            "timeReferenceStart": self.time_reference_start
        }));
    }

    fn emit_plot(&self, emitter: &Emitter) {
        let _ = emit_plot_panes_at(
            emitter,
            &self.column_states,
            &self.plot_panes,
            Some(self.position),
        );
    }

    fn emit_stream_values(&self, emitter: &Emitter) {
        let _ = emit_stream_values_for_view(
            emitter,
            &self.column_states,
            self.position,
            self.stream_value_window_seconds(),
        );
    }

    fn stream_value_window_seconds(&self) -> f64 {
        self.plot_panes
            .iter()
            .filter(|pane| pane.view.mode == PlotMode::Timeseries)
            .map(|pane| pane.view.window_seconds)
            .chain(std::iter::once(self.view.window_seconds))
            .filter(|seconds| seconds.is_finite())
            .fold(0.0, f64::max)
            .max(1e-6)
    }
}

fn main() {
    panic::set_hook(Box::new(|info| {
        eprintln!("[tio-bridge] dependency panic: {info}");
    }));

    let emitter = Emitter::new();
    install_bridge_logger(&emitter);
    emitter.status("ready", "tio-bridge started");

    let (command_tx, command_rx) = channel::unbounded::<ClientCommand>();
    spawn_stdin_reader(command_tx, emitter.clone());

    let mut session_tx: Option<Sender<SessionCommand>> = None;
    let mut playback: Option<PlaybackSession> = None;
    let mut discovery_hub: Option<DiscoveryHubHandle> = None;

    while let Ok(command) = command_rx.recv() {
        match command {
            ClientCommand::ListDevices { include_all } => {
                let devices = list_available_devices(include_all.unwrap_or(false));
                emitter.emit(&json!({
                    "type": "deviceList",
                    "devices": devices
                }));
            }
            ClientCommand::SetDiscovery {
                active,
                include_all,
            } => {
                discovery_hub = active
                    .then(|| spawn_discovery_hub(include_all.unwrap_or(false), emitter.clone()));
            }
            ClientCommand::Connect {
                url,
                route,
                log_path,
            } => {
                emitter.debug(format!("connect command received for {url}"));
                if let Some(tx) = session_tx.take() {
                    let _ = tx.send(SessionCommand::Stop);
                }
                playback = None;
                let (tx, rx) = channel::unbounded();
                let session_emitter = emitter.clone();
                thread::Builder::new()
                    .name("twinleaf-session".into())
                    .spawn(move || run_session(url, route, log_path, rx, session_emitter))
                    .expect("failed to spawn Twinleaf session thread");
                session_tx = Some(tx);
            }
            ClientCommand::SetLogging { enabled, log_path } => {
                if let Some(tx) = &session_tx {
                    let _ = tx.send(SessionCommand::SetLogging { enabled, log_path });
                } else {
                    emitter.debug("logging change ignored; no active streaming session");
                }
            }
            ClientCommand::OpenLog { path } => {
                emitter.debug(format!("openLog command received for {path}"));
                if let Some(tx) = session_tx.take() {
                    let _ = tx.send(SessionCommand::Stop);
                }
                match load_log_file(&path, &emitter) {
                    Ok(session) => {
                        emitter.status("inspection", format!("Opened log file {path}"));
                        emitter.emit(&json!({
                            "type": "metadata",
                            "devices": &session.devices
                        }));
                        session.emit_state(&emitter);
                        session.emit_plot(&emitter);
                        session.emit_stream_values(&emitter);
                        playback = Some(session);
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
                emitter.debug(format!(
                    "exportLog command received: source={source_path}, output={output_path}, format={format:?}"
                ));
                emitter.status(
                    "exporting",
                    format!("Exporting {} as {:?}", source_path, format),
                );
                let result = export_log_file(&source_path, &output_path, format, &emitter);
                emit_export_result(&emitter, request_id, output_path, format, result);
            }
            ClientCommand::Disconnect => {
                emitter.debug("disconnect command received");
                if let Some(tx) = session_tx.take() {
                    let _ = tx.send(SessionCommand::Stop);
                }
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
                if let Some(tx) = &session_tx {
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
                    emit_view_data(&emitter, request_id, Err("No active data view".to_string()));
                }
            }
            ClientCommand::SetActiveColumns { columns } => {
                if let Some(tx) = &session_tx {
                    let _ = tx.send(SessionCommand::SetActiveColumns(columns));
                } else if let Some(playback) = playback.as_mut() {
                    playback.set_active_columns(columns);
                    emit_active_columns(&emitter, &playback.active_columns);
                    playback.emit_plot(&emitter);
                    playback.emit_stream_values(&emitter);
                }
            }
            ClientCommand::SetPlotPanes { panes } => {
                if let Some(tx) = &session_tx {
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
                if let Some(tx) = &session_tx {
                    let _ = tx.send(SessionCommand::SetDerivedChannels(channels));
                } else if let Some(playback) = playback.as_mut() {
                    playback.set_derived_channels(channels);
                    playback.emit_plot(&emitter);
                    playback.emit_stream_values(&emitter);
                }
            }
            ClientCommand::SetView { view } => {
                if let Some(tx) = &session_tx {
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
                if let Some(tx) = &session_tx {
                    let _ = tx.send(SessionCommand::CallRpc {
                        request_id,
                        route,
                        name,
                        arg,
                    });
                }
            }
            ClientCommand::CheckUpgrade => {
                if let Some(tx) = &session_tx {
                    let _ = tx.send(SessionCommand::CheckUpgrade);
                }
            }
            ClientCommand::PerformUpgrade { route } => {
                if let Some(tx) = &session_tx {
                    let _ = tx.send(SessionCommand::PerformUpgrade { route });
                }
            }
            ClientCommand::Shutdown => {
                emitter.debug("shutdown command received");
                if let Some(tx) = session_tx.take() {
                    let _ = tx.send(SessionCommand::Stop);
                }
                emitter.status("exiting", "Bridge shutting down");
                break;
            }
        }
    }
    drop(discovery_hub);
}

/// Routes the twinleaf library's `log` records into the debug event stream.
/// The library reports diagnostics only through the `log` facade; without a
/// sink they vanish.
struct BridgeLogger;

static BRIDGE_LOG_EMITTER: Mutex<Option<Emitter>> = Mutex::new(None);
static BRIDGE_LOGGER: BridgeLogger = BridgeLogger;

impl log::Log for BridgeLogger {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.level() <= log::Level::Info
    }

    fn log(&self, record: &log::Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        let line = format!("{} {}: {}", record.level(), record.target(), record.args());
        if let Ok(guard) = BRIDGE_LOG_EMITTER.lock() {
            if let Some(emitter) = guard.as_ref() {
                emitter.debug(line);
                return;
            }
        }
        eprintln!("{line}");
    }

    fn flush(&self) {}
}

fn install_bridge_logger(emitter: &Emitter) {
    if let Ok(mut guard) = BRIDGE_LOG_EMITTER.lock() {
        *guard = Some(emitter.clone());
    }
    if log::set_logger(&BRIDGE_LOGGER).is_ok() {
        log::set_max_level(log::LevelFilter::Info);
    }
}

fn spawn_stdin_reader(command_tx: Sender<ClientCommand>, emitter: Emitter) {
    thread::Builder::new()
        .name("stdin-reader".into())
        .spawn(move || {
            let stdin = io::stdin();
            for line in stdin.lock().lines() {
                match line {
                    Ok(line) if line.trim().is_empty() => {}
                    Ok(line) => match serde_json::from_str::<ClientCommand>(&line) {
                        Ok(command) => {
                            if command_tx.send(command).is_err() {
                                break;
                            }
                        }
                        Err(err) => emitter.error(format!("Invalid command: {err}: {line}")),
                    },
                    Err(err) => {
                        emitter.error(format!("stdin error: {err}"));
                        break;
                    }
                }
            }
        })
        .expect("failed to spawn stdin reader");
}

/// How long the one-shot `listDevices` path browses before reporting.
/// Discovery keeps producing events past this; the live path (`setDiscovery`)
/// streams them instead of sampling once.
const DEVICE_LIST_WINDOW: Duration = Duration::from_millis(1500);

fn local_proxy_row() -> AvailableDevice {
    AvailableDevice {
        url: "tcp://localhost".to_string(),
        label: "Local tio-proxy".to_string(),
        kind: "tcp".to_string(),
        detail: "tcp://localhost:7855".to_string(),
        routes: Vec::new(),
    }
}

fn discovery_config(include_all: bool) -> DiscoveryConfig {
    DiscoveryConfig {
        include_unknown: include_all,
        network: true,
        probe_names: true,
        prefer_udp: false,
    }
}

/// Folds `DiscoveryEvent`s into the `deviceList` snapshot the UI renders. The
/// library owns enumeration and probing (names, subdevice routes); this only
/// maps its events onto the Swift-facing DTOs.
struct DiscoveryState {
    entries: Vec<DiscoveredEntry>,
    network_unavailable: Option<String>,
}

struct DiscoveredEntry {
    url: String,
    interface: PortInterface,
    name: Option<String>,
    routes: Option<Vec<AvailableRoute>>,
}

impl DiscoveryState {
    fn new() -> Self {
        Self {
            entries: Vec::new(),
            network_unavailable: None,
        }
    }

    fn apply(&mut self, event: DiscoveryEvent) {
        match event {
            DiscoveryEvent::Added(device) => {
                if let Some(entry) = self.entries.iter_mut().find(|e| e.url == device.url) {
                    if device.name.is_some() {
                        entry.name = device.name;
                    }
                } else {
                    self.entries.push(DiscoveredEntry {
                        url: device.url,
                        interface: device.interface,
                        name: device.name,
                        routes: None,
                    });
                }
            }
            DiscoveryEvent::Named { url, name } => {
                if let Some(entry) = self.entries.iter_mut().find(|e| e.url == url) {
                    entry.name = Some(name);
                }
            }
            DiscoveryEvent::Subdevices { url, routes } => {
                if let Some(entry) = self.entries.iter_mut().find(|e| e.url == url) {
                    entry.routes = Some(
                        routes
                            .into_iter()
                            .map(|named| AvailableRoute {
                                route: route_string(&named.route),
                                name: named.name,
                            })
                            .collect(),
                    );
                }
            }
            DiscoveryEvent::Removed { url } => {
                self.entries.retain(|e| e.url != url);
            }
            DiscoveryEvent::NetworkUnavailable { reason } => {
                self.network_unavailable = Some(reason);
            }
        }
    }

    fn snapshot(&self) -> Vec<AvailableDevice> {
        let mut devices = vec![local_proxy_row()];
        devices.extend(self.entries.iter().map(DiscoveredEntry::to_available));
        devices
    }
}

impl DiscoveredEntry {
    fn to_available(&self) -> AvailableDevice {
        if matches!(self.interface, PortInterface::Network) {
            let scheme = self.url.split("://").next().unwrap_or("network");
            return AvailableDevice {
                label: self.name.clone().unwrap_or_else(|| self.url.clone()),
                kind: "network".to_string(),
                detail: format!("{} \u{b7} {}", scheme.to_uppercase(), self.url),
                url: self.url.clone(),
                routes: self.routes.clone().unwrap_or_default(),
            };
        }

        let kind = serial_device_kind(&self.interface).to_string();
        let interface = interface_detail(&self.interface);
        let routes = self.routes.clone().unwrap_or_default();
        let root_name = routes
            .iter()
            .find(|route| route.route == "/")
            .and_then(|route| route.name.as_deref())
            .filter(|name| !name.is_empty())
            .map(str::to_string)
            .or_else(|| self.name.clone());
        let detail = if self.routes.is_some() {
            let attached_count = routes.iter().filter(|route| route.route != "/").count();
            let attached_detail = match attached_count {
                0 => "no attached sensors".to_string(),
                1 => "1 attached sensor".to_string(),
                count => format!("{count} attached sensors"),
            };
            format!("{interface}; {attached_detail}")
        } else {
            interface
        };
        AvailableDevice {
            url: self.url.clone(),
            label: root_name.unwrap_or_else(|| kind.clone()),
            kind,
            detail,
            routes,
        }
    }
}

fn serial_device_kind(interface: &PortInterface) -> &'static str {
    match interface {
        PortInterface::FTDI => "Twinleaf FTDI",
        PortInterface::STM32 => "Twinleaf STM32",
        PortInterface::Unknown(_, _) => "USB serial",
        PortInterface::Network => "Network",
    }
}

fn route_string(route: &DeviceRoute) -> String {
    let route = route.to_string();
    if route.is_empty() {
        "/".to_string()
    } else {
        route
    }
}

fn interface_detail(interface: &PortInterface) -> String {
    match interface {
        PortInterface::FTDI => "VID 0403, PID 6015".to_string(),
        PortInterface::STM32 => "VID 0483, PID 5740".to_string(),
        PortInterface::Unknown(vid, pid) => format!("VID {vid:04x}, PID {pid:04x}"),
        PortInterface::Network => "Network".to_string(),
    }
}

fn list_available_devices(include_all: bool) -> Vec<AvailableDevice> {
    #[cfg(not(any(feature = "serial", feature = "mdns")))]
    {
        let _ = include_all;
        vec![local_proxy_row()]
    }
    #[cfg(any(feature = "serial", feature = "mdns"))]
    {
        let discovery = Discovery::start(discovery_config(include_all));
        let mut state = DiscoveryState::new();
        let deadline = Instant::now() + DEVICE_LIST_WINDOW;
        while let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
            match discovery.events().recv_timeout(remaining) {
                Ok(event) => state.apply(event),
                Err(_) => break,
            }
        }
        state.snapshot()
    }
}

/// Live device discovery for the connection view: a background thread owns a
/// `Discovery`, folds its events, and pushes a fresh `deviceList` snapshot
/// whenever it changes. Dropping the handle stops the thread and the browse.
struct DiscoveryHubHandle {
    stop_tx: Sender<()>,
}

impl Drop for DiscoveryHubHandle {
    fn drop(&mut self) {
        let _ = self.stop_tx.send(());
    }
}

fn spawn_discovery_hub(include_all: bool, emitter: Emitter) -> DiscoveryHubHandle {
    let (stop_tx, stop_rx) = channel::bounded(1);
    thread::Builder::new()
        .name("discovery-hub".into())
        .spawn(move || {
            let discovery = Discovery::start(discovery_config(include_all));
            let mut state = DiscoveryState::new();
            let mut last_snapshot: Option<Vec<AvailableDevice>> = None;
            let mut warned_network = false;

            let sync = |state: &DiscoveryState,
                        last_snapshot: &mut Option<Vec<AvailableDevice>>,
                        warned_network: &mut bool| {
                if !*warned_network {
                    if let Some(reason) = state.network_unavailable.as_ref() {
                        emitter.debug(format!("network discovery unavailable: {reason}"));
                        *warned_network = true;
                    }
                }
                let snapshot = state.snapshot();
                if last_snapshot.as_ref() != Some(&snapshot) {
                    emitter.emit(&json!({
                        "type": "deviceList",
                        "devices": snapshot
                    }));
                    *last_snapshot = Some(snapshot);
                }
            };

            // Serial rows are queued synchronously by `start`, so the first
            // snapshot is useful immediately.
            for event in discovery.events().try_iter() {
                state.apply(event);
            }
            sync(&state, &mut last_snapshot, &mut warned_network);

            loop {
                channel::select! {
                    recv(discovery.events()) -> event => {
                        let Ok(event) = event else { return };
                        state.apply(event);
                        // Coalesce the burst a probe pass produces.
                        for event in discovery.events().try_iter() {
                            state.apply(event);
                        }
                        sync(&state, &mut last_snapshot, &mut warned_network);
                    },
                    recv(stop_rx) -> _ => return,
                }
            }
        })
        .expect("failed to spawn discovery hub");
    DiscoveryHubHandle { stop_tx }
}

/// Serve several sensors as one device tree on a loopback TCP port: sensor k
/// is mounted at route /k. The session connects to the returned URL and the
/// combined tree behaves exactly like a hub. The mount thread runs until the
/// session's connection closes (or any mounted sensor's proxy thread dies).
fn start_multi_sensor_mount(urls: Vec<String>, emitter: Emitter) -> Result<String, String> {
    let listener = std::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
        .map_err(|err| format!("could not bind a loopback port: {err}"))?;
    let loopback_port = listener
        .local_addr()
        .map_err(|err| format!("could not read the loopback address: {err}"))?
        .port();

    thread::Builder::new()
        .name("twinleaf-multi-mount".into())
        .spawn(move || run_multi_sensor_mount(listener, urls, emitter))
        .map_err(|err| format!("could not spawn the mount thread: {err}"))?;

    Ok(format!("tcp://127.0.0.1:{loopback_port}"))
}

fn run_multi_sensor_mount(listener: std::net::TcpListener, urls: Vec<String>, emitter: Emitter) {
    struct MountLink {
        prefix: DeviceRoute,
        interface: proxy::Interface,
        status_rx: Receiver<proxy::Event>,
    }

    let mut links = Vec::with_capacity(urls.len());
    for (index, sensor_url) in urls.iter().enumerate() {
        let Ok(prefix) = DeviceRoute::from_str(&format!("/{index}")) else {
            emitter.debug(format!("multi-mount: invalid route /{index}"));
            return;
        };
        emitter.debug(format!("multi-mount: {sensor_url} at {prefix}"));
        let (status_tx, status_rx) = channel::bounded(100);
        let interface = proxy::Interface::new_proxy(
            sensor_url,
            Some(CONNECTION_STARTUP_TIMEOUT),
            Some(status_tx),
        );
        links.push(MountLink {
            prefix,
            interface,
            status_rx,
        });
    }

    // Open each mount's port right away (before blocking on accept): a proxy
    // interface with no ports can shut down on an early connection failure,
    // after which `new_port` is refused.
    let mut ports = Vec::with_capacity(links.len());
    for link in &links {
        match link.interface.new_port(
            Some(Duration::from_millis(2000)),
            DeviceRoute::root(),
            usize::MAX,
            true,
            true,
        ) {
            Ok(port) => ports.push(port),
            Err(err) => {
                emitter.debug(format!(
                    "multi-mount: could not open a port for {}: {err:?}",
                    link.prefix
                ));
                return;
            }
        }
    }

    // The only client is this process's own session proxy.
    let Ok((stream, _)) = listener.accept() else {
        emitter.debug("multi-mount: accept failed");
        return;
    };
    drop(listener);

    let (rx_send, client_rx) =
        tio::transport::Port::rx_channel_custom(proxy::Interface::get_client_tx_channel_size());
    let client = match tio::transport::Port::from_tcp_stream_custom(
        stream,
        tio::transport::Port::rx_to_channel(rx_send),
        proxy::Interface::get_client_rx_channel_size(),
    ) {
        Ok(client) => client,
        Err(err) => {
            emitter.debug(format!(
                "multi-mount: could not wrap the session stream: {err:?}"
            ));
            return;
        }
    };

    // Select slots: 0 is the session's traffic; then each link contributes
    // its sensor packets (slot 1 + 2i) and its proxy status (slot 2 + 2i).
    let mut sel = channel::Select::new();
    sel.recv(&client_rx);
    for (link, port) in links.iter().zip(&ports) {
        sel.recv(port.receiver());
        sel.recv(&link.status_rx);
    }

    let mut dropped_packets: u64 = 0;
    loop {
        let oper = sel.select();
        let slot = oper.index();
        if slot == 0 {
            let Ok(Ok(mut pkt)) = oper.recv(&client_rx) else {
                emitter.debug("multi-mount: session disconnected; shutting down");
                break;
            };
            let mut destination = None;
            for (link, port) in links.iter().zip(&ports) {
                if let Ok(relative) = link.prefix.relative_route(&pkt.routing) {
                    destination = Some((relative, port));
                    break;
                }
            }
            let Some((relative, port)) = destination else {
                // Root-addressed heartbeats keep each sensor's link alive
                // (devices expire clients that go quiet); broadcast them to
                // every mount, exactly as each sensor would receive over a
                // direct connection. Other root-addressed packets have no
                // single destination and are dropped.
                if pkt.routing.len() == 0 {
                    if let Payload::Heartbeat(_) = pkt.payload {
                        for port in &ports {
                            let _ = port.try_send(pkt.clone());
                        }
                    }
                }
                continue;
            };
            pkt.routing = relative;
            if port.try_send(pkt).is_err() {
                emitter.debug("multi-mount: forwarding to a sensor failed");
                break;
            }
        } else {
            let link_index = (slot - 1) / 2;
            let link = &links[link_index];
            if (slot - 1) % 2 == 0 {
                let Ok(mut pkt) = oper.recv(ports[link_index].receiver()) else {
                    emitter.debug(format!("multi-mount: lost the sensor at {}", link.prefix));
                    break;
                };
                let Ok(absolute) = link.prefix.absolute_route(&pkt.routing) else {
                    continue;
                };
                pkt.routing = absolute;
                if pkt.routing.len() > tio::proto::TIO_PACKET_MAX_ROUTING_SIZE {
                    continue;
                }
                match client.try_send(pkt) {
                    Ok(()) => {}
                    Err(tio::transport::SendError::Full) => {
                        dropped_packets += 1;
                        if dropped_packets.is_power_of_two() {
                            emitter.debug(format!(
                                "multi-mount: dropped {dropped_packets} packet(s); session is slow"
                            ));
                        }
                    }
                    Err(_) => {
                        emitter.debug("multi-mount: session connection closed");
                        break;
                    }
                }
            } else {
                let Ok(event) = oper.recv(&link.status_rx) else {
                    emitter.debug(format!("multi-mount: proxy ended at {}", link.prefix));
                    break;
                };
                emitter.debug(format!("multi-mount {}: {event:?}", link.prefix));
            }
        }
    }
}

// MARK: - Health diagnostics
//
// Per-stream timing/rate diagnostics equivalent to `tio health`. The math
// (incremental OLS for drift and rate, a ring-buffer jitter window) is ported
// from twinleaf-tools, which is a binary crate the bridge can't depend on.

/// Incremental ordinary-least-squares slope, anchored at the first point to
/// keep the sums small.
#[derive(Default)]
struct OnlineSlope {
    n: u64,
    sum_x: f64,
    sum_y: f64,
    sum_xx: f64,
    sum_xy: f64,
    x0: f64,
    y0: f64,
}

impl OnlineSlope {
    fn push(&mut self, x: f64, y: f64) {
        if self.n == 0 {
            self.x0 = x;
            self.y0 = y;
        }
        let dx = x - self.x0;
        let dy = y - self.y0;
        self.n += 1;
        self.sum_x += dx;
        self.sum_y += dy;
        self.sum_xx += dx * dx;
        self.sum_xy += dx * dy;
    }

    fn slope(&self) -> Option<f64> {
        if self.n < 2 {
            return None;
        }
        let denom = self.n as f64 * self.sum_xx - self.sum_x * self.sum_x;
        if denom.abs() < f64::EPSILON {
            return None;
        }
        Some((self.n as f64 * self.sum_xy - self.sum_x * self.sum_y) / denom)
    }

    fn reset(&mut self) {
        *self = Self::default();
    }
}

/// Fixed-capacity ring of inter-sample timing deltas (ms); reports their stddev.
struct JitterWindow {
    buf: Vec<f64>,
    idx: usize,
    filled: bool,
}

impl JitterWindow {
    fn new(seconds: u64, hz_guess: f64) -> Self {
        let cap = ((seconds as f64 * hz_guess).round() as usize).max(16);
        Self {
            buf: vec![0.0; cap],
            idx: 0,
            filled: false,
        }
    }

    fn push(&mut self, value: f64) {
        self.buf[self.idx] = value;
        self.idx = (self.idx + 1) % self.buf.len();
        if self.idx == 0 {
            self.filled = true;
        }
    }

    fn std_ms(&self) -> f64 {
        let n = if self.filled {
            self.buf.len()
        } else {
            self.idx
        };
        if n == 0 {
            return 0.0;
        }
        let mean = self.buf[..n].iter().sum::<f64>() / n as f64;
        let var = self.buf[..n]
            .iter()
            .map(|x| (x - mean).powi(2))
            .sum::<f64>()
            / n as f64;
        var.sqrt()
    }
}

#[derive(Default)]
struct StreamHealth {
    name: String,
    host_epoch: Option<Instant>,
    drift_slope: OnlineSlope,
    drift_s: f64,
    ppm: f64,
    last_host: Option<Instant>,
    last_data: Option<f64>,
    jitter_ms: f64,
    jitter_window: Option<JitterWindow>,
    last_n: Option<u32>,
    samples_dropped: u64,
    session_id: Option<u32>,
    rate_slope: OnlineSlope,
    received_count: u64,
    rate_smps: f64,
    last_seen: Option<Instant>,
}

impl StreamHealth {
    fn on_sample(&mut self, sample_n: u32, t_data: f64, now: Instant) {
        let epoch = *self.host_epoch.get_or_insert(now);
        let host_time = now.duration_since(epoch).as_secs_f64();

        let window = self
            .jitter_window
            .get_or_insert_with(|| JitterWindow::new(HEALTH_JITTER_WINDOW_SECONDS, 100.0));
        if let (Some(last_host), Some(last_data)) = (self.last_host, self.last_data) {
            let dh = now.duration_since(last_host).as_secs_f64();
            let dd = t_data - last_data;
            window.push((dd - dh) * 1000.0);
            self.jitter_ms = window.std_ms();
        }
        self.last_host = Some(now);
        self.last_data = Some(t_data);

        self.drift_slope.push(host_time, t_data);
        if self.drift_slope.n >= HEALTH_MIN_DRIFT_SAMPLES {
            if let Some(beta) = self.drift_slope.slope() {
                let host_elapsed = host_time - self.drift_slope.x0;
                self.drift_s = (beta - 1.0) * host_elapsed;
                self.ppm = (beta - 1.0) * 1e6;
            }
        }

        self.received_count += 1;
        self.rate_slope.push(host_time, self.received_count as f64);
        if let Some(slope) = self.rate_slope.slope() {
            self.rate_smps = slope;
        }

        self.last_n = Some(sample_n);
    }

    fn reset_timing(&mut self) {
        self.drift_slope.reset();
        self.drift_s = 0.0;
        self.ppm = 0.0;
        self.last_host = None;
        self.last_data = None;
        self.jitter_ms = 0.0;
        self.jitter_window = None;
        self.last_n = None;
    }

    fn reset_for_new_session(&mut self, session_id: u32) {
        self.reset_timing();
        self.samples_dropped = 0;
        self.session_id = Some(session_id);
    }

    fn stale_threshold(&self) -> Duration {
        if self.rate_slope.n >= 2 && self.rate_smps > 0.0 {
            Duration::from_secs_f64(2.0 / self.rate_smps).max(HEALTH_STALE_FLOOR)
        } else {
            HEALTH_STALE_FLOOR
        }
    }

    fn is_stale(&self, now: Instant) -> bool {
        self.last_seen
            .map(|seen| now.duration_since(seen) > self.stale_threshold())
            .unwrap_or(true)
    }
}

#[derive(Default)]
struct HealthMonitor {
    streams: HashMap<(DeviceRoute, u8), StreamHealth>,
}

impl HealthMonitor {
    fn observe_batch(&mut self, batch: &SampleBatch, now: Instant) {
        let key = (batch.route(), batch.stream_key().stream_id);
        let stats = self.streams.entry(key).or_insert_with(|| StreamHealth {
            name: batch.stream().name.clone(),
            session_id: Some(batch.device().session_id),
            ..Default::default()
        });
        stats.name = batch.stream().name.clone();

        // A batch carries at most one boundary, anchored at its first row.
        if let Some(boundary) = batch.boundary() {
            match boundary.reason {
                BoundaryReason::SessionChanged { new, .. } => stats.reset_for_new_session(new),
                BoundaryReason::SamplesLost { expected, received } => {
                    stats.samples_dropped += u64::from(received.wrapping_sub(expected));
                }
                _ => {}
            }
        }

        for (&n, &t) in batch.sample_numbers().iter().zip(batch.timestamps()) {
            if stats.last_n.map(|last| n != last).unwrap_or(true) {
                stats.last_seen = Some(now);
            }
            stats.on_sample(n, t, now);
        }
    }

    /// Drop all streams for a route (device reset / disconnect).
    fn reset_route(&mut self, route: &DeviceRoute) {
        self.streams.retain(|(r, _), _| r != route);
    }

    fn snapshot(&self, now: Instant) -> Value {
        let mut entries: Vec<(&(DeviceRoute, u8), &StreamHealth)> = self.streams.iter().collect();
        entries.sort_by(|a, b| (a.0 .0.to_string(), a.0 .1).cmp(&(b.0 .0.to_string(), b.0 .1)));
        let streams: Vec<Value> = entries
            .into_iter()
            .map(|((route, stream_id), stats)| {
                json!({
                    "route": route.to_string(),
                    "streamId": stream_id,
                    "name": stats.name,
                    "rateHz": finite_or_null(stats.rate_smps),
                    "ppm": finite_or_null(stats.ppm),
                    "driftSeconds": finite_or_null(stats.drift_s),
                    "jitterMs": finite_or_null(stats.jitter_ms),
                    "received": stats.received_count,
                    "dropped": stats.samples_dropped,
                    "sessionId": stats.session_id,
                    "stale": stats.is_stale(now),
                })
            })
            .collect();
        json!({ "type": "health", "streams": streams })
    }
}

fn finite_or_null(value: f64) -> Value {
    if value.is_finite() {
        json!(value)
    } else {
        Value::Null
    }
}

enum BridgeTreeMsg {
    Items(Vec<TreeItem>),
    /// The parser panicked inside `recv`; the worker backs off and keeps
    /// reading, so a malformed packet degrades one drain rather than the
    /// whole session.
    Panic(String),
    Disconnected,
}

/// How long the worker lingers after the first item to bundle the packets
/// right behind it, and the most items one bundle may carry. The linger
/// bounds the added delivery latency; it sits far under the 33 ms plot
/// cadence.
const TREE_BUNDLE_WINDOW: Duration = Duration::from_millis(2);
const TREE_BUNDLE_CAP: usize = 256;

/// Owns the `DeviceTree` on a dedicated thread and forwards its items over a
/// channel, so the session loop can `select!` across data, commands, proxy
/// status, and timers. Items travel in bundles so a 1 kHz stream wakes the
/// session loop per burst rather than per packet. The worker exits when the
/// receiver is dropped.
fn spawn_bridge_tree_worker(mut tree: DeviceTree) -> Receiver<BridgeTreeMsg> {
    let (tx, rx) = channel::unbounded();
    thread::Builder::new()
        .name("tree-worker".into())
        .spawn(move || loop {
            let mut items = Vec::new();
            let mut failure = None;

            match panic::catch_unwind(AssertUnwindSafe(|| tree.recv())) {
                Ok(Ok(item)) => items.push(item),
                Ok(Err(_)) => failure = Some(BridgeTreeMsg::Disconnected),
                Err(panic) => failure = Some(BridgeTreeMsg::Panic(panic_message(panic))),
            }

            if failure.is_none() {
                let deadline = Instant::now() + TREE_BUNDLE_WINDOW;
                while items.len() < TREE_BUNDLE_CAP {
                    match panic::catch_unwind(AssertUnwindSafe(|| tree.recv_deadline(deadline))) {
                        Ok(Ok(item)) => items.push(item),
                        Ok(Err(proxy::RecvTimeoutError::Timeout)) => break,
                        Ok(Err(proxy::RecvTimeoutError::ProxyDisconnected)) => {
                            failure = Some(BridgeTreeMsg::Disconnected);
                            break;
                        }
                        Err(panic) => {
                            failure = Some(BridgeTreeMsg::Panic(panic_message(panic)));
                            break;
                        }
                    }
                }
            }

            if !items.is_empty() && tx.send(BridgeTreeMsg::Items(items)).is_err() {
                return;
            }
            match failure {
                None => {}
                Some(BridgeTreeMsg::Disconnected) => {
                    let _ = tx.send(BridgeTreeMsg::Disconnected);
                    return;
                }
                Some(message) => {
                    if tx.send(message).is_err() {
                        return;
                    }
                    thread::sleep(Duration::from_millis(250));
                }
            }
        })
        .expect("failed to spawn tree worker");
    rx
}

fn run_session(
    url: String,
    route: Option<String>,
    log_path: Option<String>,
    command_rx: Receiver<SessionCommand>,
    emitter: Emitter,
) {
    let root_route = match route
        .as_deref()
        .unwrap_or("/")
        .parse::<String>()
        .ok()
        .and_then(|s| DeviceRoute::from_str(&s).ok())
    {
        Some(route) => route,
        None => {
            emitter.error("Invalid route");
            return;
        }
    };

    emitter.status("connecting", format!("Connecting to {url}"));
    emitter.debug(format!("session starting: url={url}, route={root_route}"));

    // Multiple whitespace-separated URLs are mounted at /0, /1, ... behind an
    // in-process loopback proxy, so the rest of the session sees one combined
    // device tree exactly as it would behind a hub.
    let sensor_urls: Vec<String> = url.split_whitespace().map(str::to_string).collect();
    let connect_url = if sensor_urls.len() > 1 {
        match start_multi_sensor_mount(sensor_urls, emitter.clone()) {
            Ok(loopback_url) => loopback_url,
            Err(err) => {
                emitter.error(format!("Could not start the multi-sensor mount: {err}"));
                return;
            }
        }
    } else {
        url.clone()
    };

    let (proxy_status_tx, proxy_status_rx) = channel::unbounded();
    let (status_tx, mut status_rx) = channel::unbounded();
    spawn_proxy_status_forwarder(url.clone(), proxy_status_rx, status_tx, emitter.clone());
    let proxy = Arc::new(proxy::Interface::new_proxy(
        &connect_url,
        Some(CONNECTION_STARTUP_TIMEOUT),
        Some(proxy_status_tx),
    ));

    let mut pending_startup_commands = VecDeque::new();
    let retry_transient_connect_failures = is_retryable_connect_url(&connect_url);
    if !wait_for_proxy_connection(
        &status_rx,
        &command_rx,
        &mut pending_startup_commands,
        &emitter,
        CONNECTION_STARTUP_TIMEOUT,
        retry_transient_connect_failures,
    ) {
        return;
    }

    let mut discovery = match discover_devices_until_available(
        &proxy,
        &url,
        &root_route,
        &command_rx,
        &mut pending_startup_commands,
        &emitter,
        CONNECTION_STARTUP_TIMEOUT,
    ) {
        Some(discovery) => discovery,
        None => return,
    };

    emitter.status(
        "metadata",
        format!("Loaded metadata for {} device(s)", discovery.devices.len()),
    );
    emit_metadata_devices(&emitter, &discovery.devices);

    let mut column_states = build_column_states(&discovery.devices);
    let mut rpc_index = build_rpc_index(&discovery.devices);
    let mut active_columns: HashSet<ColumnKeyDto> = HashSet::new();
    let mut view = ViewConfig::default();
    let mut plot_panes = default_plot_panes(&view);
    let mut fft_workers: HashMap<usize, FftWorker> = HashMap::new();
    let mut derived_channels: Vec<DerivedChannelDto> = Vec::new();
    let mut derived_worker = DerivedWorker::new();
    let mut logger = PacketLogger::new(log_path, &emitter);
    logger.write_startup_metadata(&discovery.devices, &emitter);
    let mut plot_profiler = PlotCadenceProfiler::new();
    let mut ingest_profiler = StreamIngestProfiler::new();
    let mut stream_value_profiler = StreamValueEmitProfiler::new();
    let mut loop_profiler = SessionLoopProfiler::new();
    let packet_monitor_port = match proxy.subtree_full(root_route.clone()) {
        Ok(port) => Some(port),
        Err(err) => {
            emitter.error(format!("Failed to open packet monitor port: {err:?}"));
            None
        }
    };
    let device_tree = match DeviceTree::open(&proxy, root_route) {
        Ok(tree) => tree,
        Err(err) => {
            emitter.error(format!("Failed to open device tree: {err:?}"));
            return;
        }
    };
    let mut tree_rx = spawn_bridge_tree_worker(device_tree);

    emitter.status("streaming", format!("Streaming from {url}"));
    // Lazily check for available firmware upgrades on a background thread so
    // neither the network round-trip nor the per-device dev.desc RPC blocks the
    // streaming loop.
    spawn_upgrade_check(
        Arc::clone(&proxy),
        discovery.devices.clone(),
        emitter.clone(),
    );
    let mut last_stream_value_emit = Instant::now();
    let mut health = HealthMonitor::default();
    let mut last_health_emit = Instant::now();
    let mut last_log_flush = Instant::now();
    let mut last_log_progress_packets = 0;
    let mut log_data_start: Option<f64> = None;
    let mut log_data_end: Option<f64> = None;
    let mut log_time_reference_start: Option<f64> = None;
    let mut latest_stream_timestamp_by_route: HashMap<DeviceRoute, f64> = HashMap::new();
    let mut last_rpc_metadata_recovery = Instant::now();
    let mut last_sample_number_by_stream: HashMap<(DeviceRoute, u8), u32> = HashMap::new();
    let mut last_reset_refresh_by_route: HashMap<DeviceRoute, Instant> = HashMap::new();

    // Accumulates across select iterations; recorded and reset on every tick,
    // so a profile window covers one tick interval like the old poll loop.
    let mut loop_profile = SessionLoopProfile::default();
    let mut monitor_port_alive = packet_monitor_port.is_some();
    let tick = channel::tick(Duration::from_millis(10));
    // Plot frames get their own timer: gating the emit on the 10 ms tick
    // quantizes a 33 ms budget up to ~40 ms and drops the frame rate.
    let plot_tick = channel::tick(Duration::from_millis(33));

    loop {
        // Startup commands queued while connecting run before live traffic.
        let command = if let Some(queued) = pending_startup_commands.pop_front() {
            Ok(queued)
        } else {
            channel::select! {
                recv(tree_rx) -> msg => {
                    match msg {
                        Ok(BridgeTreeMsg::Items(items)) => for item in items {
                            match item {
                            TreeItem::Batch(batch) => {
                            let process_start = Instant::now();
                            let now = Instant::now();
                            health.observe_batch(&batch, now);
                            let route = batch.route();
                            let stream_key = (route, batch.stream_key().stream_id);
                            // A sample counter that goes backward means the
                            // device rebooted (its counter restarted).
                            let mut device_reset = false;
                            if let (Some(&first_n), Some(&last_n)) = (
                                batch.sample_numbers().first(),
                                last_sample_number_by_stream.get(&stream_key),
                            ) {
                                if first_n < last_n {
                                    device_reset = true;
                                }
                            }
                            if let Some(&n) = batch.sample_numbers().last() {
                                last_sample_number_by_stream.insert(stream_key, n);
                            }

                            if let Some(first_row) = batch.row(0) {
                                let batch_start = first_row.timestamp_begin();
                                if batch_start.is_finite() {
                                    log_data_start = Some(
                                        log_data_start
                                            .map(|start| start.min(batch_start))
                                            .unwrap_or(batch_start),
                                    );
                                }
                            }
                            if let Some(&batch_end) = batch.timestamps().last() {
                                if batch_end.is_finite() {
                                    log_data_end = Some(
                                        log_data_end
                                            .map(|end| end.max(batch_end))
                                            .unwrap_or(batch_end),
                                    );
                                    latest_stream_timestamp_by_route.insert(route, batch_end);
                                }
                            }
                            log_time_reference_start = earliest_time(
                                log_time_reference_start,
                                batch_time_reference_start(&batch),
                            );
                            process_batch(
                                &batch,
                                &mut column_states,
                                &active_columns,
                                &plot_panes,
                                live_retention_seconds_for_panes(&plot_panes, &view, &derived_channels),
                                Some(&mut ingest_profiler),
                            );
                            loop_profile.samples += batch.len();
                            loop_profile.process_elapsed += process_start.elapsed();

                            if device_reset {
                                emitter.debug(format!(
                                    "sample number went backward on {route}; treating as device reset"
                                ));
                                flush_route_history(&route.to_string(), &mut column_states);
                                fft_workers.clear();
                                health.reset_route(&route);
                                // Drop baselines for the route's other streams so their
                                // first post-reset sample doesn't re-trigger.
                                last_sample_number_by_stream.retain(|(r, _), _| r != &route);

                                let refresh_due = last_reset_refresh_by_route
                                    .get(&route)
                                    .is_none_or(|at| at.elapsed() >= DEVICE_RESET_REFRESH_COOLDOWN);
                                if refresh_due {
                                    last_reset_refresh_by_route.insert(route, Instant::now());
                                    emitter.status(
                                        "metadata",
                                        format!("Device on {route} restarted; reloading settings"),
                                    );
                                    if refresh_route_metadata(
                                        &proxy,
                                        &url,
                                        &route,
                                        &root_route,
                                        &emitter,
                                        &mut discovery,
                                        &mut column_states,
                                        &mut rpc_index,
                                    ) {
                                        emit_metadata_devices(&emitter, &discovery.devices);
                                    }
                                    emitter.status("streaming", format!("Streaming from {url}"));
                                }
                            }
                        }
                            TreeItem::Event(event) => {
                            let event_start = Instant::now();
                            loop_profile.device_events += 1;
                            match event {
                                TreeEvent::Device { route, event } => {
                                    if let DeviceEvent::RpcInvalidated(method) = &event {
                                        emit_rpc_invalidated(&emitter, &route, method);
                                    }
                                    emitter.emit(&json!({
                                        "type": "deviceEvent",
                                        "route": route.to_string(),
                                        "event": format!("{event:?}")
                                    }));
                                }
                                TreeEvent::RouteDiscovered(route) => {
                                    if add_late_discovered_route(
                                        &proxy,
                                        &url,
                                        &route,
                                        &root_route,
                                        &emitter,
                                        &mut discovery,
                                        &mut column_states,
                                        &mut rpc_index,
                                    ) {
                                        emit_metadata_devices(&emitter, &discovery.devices);
                                    }
                                }
                            }
                            loop_profile.event_elapsed += event_start.elapsed();
                        }
                            }
                        },
                        Ok(BridgeTreeMsg::Panic(message)) => {
                            emitter.error(format!(
                                "Twinleaf parser panic while draining stream data: {message}"
                            ));
                        }
                        Ok(BridgeTreeMsg::Disconnected) | Err(_) => {
                            emitter.error("Twinleaf stream ended: proxy disconnected");
                            tree_rx = channel::never();
                        }
                    }
                    continue;
                },
                recv(status_rx) -> status => {
                    match status {
                        Ok(status) => {
                            loop_profile.status_events += 1;
                            emitter.emit(&json!({
                                "type": "proxyEvent",
                                "event": format!("{status:?}")
                            }));
                        }
                        Err(_) => status_rx = channel::never(),
                    }
                    continue;
                },
                recv(plot_tick) -> _ => {
                    let emit_start = Instant::now();
                    let stats = emit_live_plot(
                        &emitter,
                        &column_states,
                        &active_columns,
                        &plot_panes,
                        &mut fft_workers,
                    );
                    loop_profile.plot_elapsed = emit_start.elapsed();
                    if let Some(stats) = stats {
                        plot_profiler.record(emit_start.elapsed(), stats);
                        loop_profile.plot_emits = 1;
                    }
                    continue;
                },
                recv(tick) -> _ => {
                    let tick_start = Instant::now();
                    if monitor_port_alive {
                        if let Some(port) = &packet_monitor_port {
                            let raw_log_start = Instant::now();
                            let (raw_packets, alive) = drain_packet_monitor_port(
                                port,
                                &root_route,
                                &mut logger,
                                &latest_stream_timestamp_by_route,
                                &emitter,
                            );
                            loop_profile.raw_packets += raw_packets;
                            loop_profile.raw_log_elapsed += raw_log_start.elapsed();
                            monitor_port_alive = alive;
                        }
                    }

                    if !discovery.incomplete_rpc_routes.is_empty()
                        && last_rpc_metadata_recovery.elapsed() >= RPC_METADATA_RECOVERY_INTERVAL
                    {
                        if recover_incomplete_rpc_metadata(&proxy, &mut discovery, &emitter) {
                            rpc_index = build_rpc_index(&discovery.devices);
                            emit_metadata_devices(&emitter, &discovery.devices);
                        }
                        last_rpc_metadata_recovery = Instant::now();
                    }

                    if !derived_channels.is_empty() {
                        update_derived_channels(
                            &derived_channels,
                            &mut column_states,
                            &mut derived_worker,
                            live_retention_seconds_for_panes(&plot_panes, &view, &derived_channels),
                        );
                    }

                    if last_stream_value_emit.elapsed() >= Duration::from_millis(100) {
                        let emit_start = Instant::now();
                        let value_count = emit_stream_values(&emitter, &column_states);
                        loop_profile.stream_values = value_count;
                        loop_profile.stream_value_elapsed = emit_start.elapsed();
                        stream_value_profiler.record(emit_start.elapsed(), value_count, column_states.len());
                        last_stream_value_emit = Instant::now();
                    }

                    if last_health_emit.elapsed() >= HEALTH_EMIT_INTERVAL {
                        emitter.emit(&health.snapshot(Instant::now()));
                        last_health_emit = Instant::now();
                    }

                    if last_log_flush.elapsed() >= Duration::from_secs(1) {
                        let flush_start = Instant::now();
                        logger.flush();
                        if logger.packets_written != last_log_progress_packets {
                            logger.emit_progress(
                                &emitter,
                                log_data_start,
                                log_data_end,
                                log_time_reference_start,
                            );
                            last_log_progress_packets = logger.packets_written;
                        }
                        loop_profile.flushes = 1;
                        loop_profile.flush_elapsed = flush_start.elapsed();
                        last_log_flush = Instant::now();
                    }

                    loop_profile.busy_elapsed = loop_profile.status_elapsed
                        + loop_profile.command_elapsed
                        + loop_profile.process_elapsed
                        + loop_profile.raw_log_elapsed
                        + loop_profile.event_elapsed
                        + loop_profile.plot_elapsed
                        + loop_profile.stream_value_elapsed
                        + loop_profile.flush_elapsed
                        + tick_start.elapsed();
                    loop_profiler.record(
                        std::mem::take(&mut loop_profile),
                        column_states.len(),
                        active_columns.len(),
                        retained_point_count(&column_states),
                    );
                    continue;
                },
                recv(command_rx) -> command => command,
            }
        };

        let command = match command {
            Ok(command) => command,
            Err(_) => {
                // The client side dropped the command channel; no Stop is
                // coming, so shut down as if one arrived.
                logger.flush();
                emitter.status("disconnected", "Stopped streaming");
                return;
            }
        };
        let command_start = Instant::now();
        loop_profile.commands += 1;
        {
            match command {
                SessionCommand::Stop => {
                    logger.flush();
                    emitter.status("disconnected", "Stopped streaming");
                    return;
                }
                SessionCommand::SetActiveColumns(columns) => {
                    update_default_pane_columns(&mut plot_panes, columns, &view);
                    active_columns = active_columns_for_panes(&plot_panes);
                    fft_workers.clear();
                    hydrate_fpcs(&mut column_states, &plot_panes, &emitter);
                    emit_active_columns(&emitter, &active_columns);
                }
                SessionCommand::SetLogging { enabled, log_path } => {
                    logger.set_enabled(enabled, log_path, &discovery.devices, &emitter);
                    if logger.is_enabled() {
                        logger.emit_progress(
                            &emitter,
                            log_data_start,
                            log_data_end,
                            log_time_reference_start,
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
                    hydrate_fpcs(&mut column_states, &plot_panes, &emitter);
                }
                SessionCommand::SetPlotPanes(panes) => {
                    plot_panes = panes;
                    active_columns = active_columns_for_panes(&plot_panes);
                    fft_workers.clear();
                    hydrate_fpcs(&mut column_states, &plot_panes, &emitter);
                    emit_active_columns(&emitter, &active_columns);
                }
                SessionCommand::SetDerivedChannels(channels) => {
                    // Retuning a channel invalidates the history accumulated
                    // under the old parameters: points from a 10 s window and
                    // a 60 s window are not the same measurement and must not
                    // share a trace.
                    for channel in &channels {
                        let changed = derived_channels
                            .iter()
                            .find(|existing| existing.key == channel.key)
                            .is_none_or(|existing| existing != channel);
                        if changed {
                            column_states.remove(&channel.key);
                        }
                    }
                    let retained: HashSet<_> =
                        channels.iter().map(|channel| channel.key.clone()).collect();
                    column_states.retain(|key, _| !key.is_derived() || retained.contains(key));
                    derived_channels = channels;
                    emitter.debug(format!(
                        "derived channels updated: {} active",
                        derived_channels.len()
                    ));
                }
                SessionCommand::CallRpc {
                    request_id,
                    route,
                    name,
                    arg,
                } => dispatch_rpc(&proxy, &rpc_index, request_id, route, name, arg, &emitter),
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
                    let text = build_view_data_tsv(&column_states, &columns, &view, viewport_end);
                    emit_view_data(&emitter, request_id, Ok(text));
                }
                SessionCommand::CheckUpgrade => {
                    spawn_upgrade_check(
                        Arc::clone(&proxy),
                        discovery.devices.clone(),
                        emitter.clone(),
                    );
                }
                SessionCommand::PerformUpgrade { route } => {
                    spawn_upgrade_flash(Arc::clone(&proxy), route, emitter.clone());
                }
            }
        }
        loop_profile.command_elapsed += command_start.elapsed();
    }
}

fn emit_rpc_invalidated(emitter: &Emitter, route: &DeviceRoute, method: &RpcMethod) {
    match method {
        RpcMethod::Name(name) => emitter.emit(&json!({
            "type": "rpcInvalidated",
            "route": route.to_string(),
            "name": name
        })),
        RpcMethod::Id(id) => emitter.emit(&json!({
            "type": "rpcInvalidated",
            "route": route.to_string(),
            "rpcId": id
        })),
    }
}

fn emit_metadata_devices(emitter: &Emitter, devices: &[DeviceDto]) {
    emitter.emit(&json!({
        "type": "metadata",
        "devices": devices
    }));
}

/// Drop all buffered plot history for a route. Used when the device resets:
/// pre-reset points would otherwise bridge the discontinuity on screen. The
/// FPCS state rebuilds lazily from the (now empty) raw buffer on the next
/// sample.
fn flush_route_history(route: &str, column_states: &mut HashMap<ColumnKeyDto, ColumnState>) {
    for (key, state) in column_states.iter_mut() {
        if key.route == route {
            state.raw.clear();
            state.fpcs_by_pane.clear();
            state.display_value = None;
            state.display_value_x = None;
        }
    }
}

/// Re-fetch stream metadata and the RPC list for a route whose device
/// restarted, replacing its entry in the running session state. Returns true
/// when the refreshed device was applied (the caller then re-emits `metadata`,
/// which also prompts the app to reload all readable RPC values).
fn refresh_route_metadata(
    proxy: &Arc<proxy::Interface>,
    url: &str,
    route: &DeviceRoute,
    root_route: &DeviceRoute,
    emitter: &Emitter,
    discovery: &mut DeviceDiscoveryResult,
    column_states: &mut HashMap<ColumnKeyDto, ColumnState>,
    rpc_index: &mut HashMap<(String, String), RpcDto>,
) -> bool {
    let fetched = match panic::catch_unwind(AssertUnwindSafe(|| {
        fetch_device(proxy, url, route, None, emitter, false)
    })) {
        Ok(Ok(fetched)) => fetched,
        Ok(Err(err)) => {
            emitter.debug(format!("post-reset refresh of {route} failed: {err}"));
            return false;
        }
        Err(err) => {
            emitter.debug(format!(
                "post-reset refresh of {route} panicked: {}",
                panic_message(err)
            ));
            return false;
        }
    };

    let route_str = route.to_string();
    if fetched.rpc_metadata_complete {
        discovery.incomplete_rpc_routes.remove(route);
    } else {
        discovery.incomplete_rpc_routes.insert(route.clone());
    }

    for stream in &fetched.device.streams {
        for column in &stream.columns {
            let label = format!(
                "{} {}.{}",
                fetched.device.meta.name, stream.name, column.name
            );
            column_states.entry(column.key.clone()).or_insert_with(|| {
                ColumnState::new(label, column.units.clone(), stream.effective_sampling_rate)
            });
        }
    }

    rpc_index.retain(|(r, _), _| r != &route_str);
    for rpc in &fetched.device.rpcs {
        rpc_index.insert(
            (fetched.device.route.clone(), rpc.name.clone()),
            rpc.clone(),
        );
    }

    if let Some(existing) = discovery
        .devices
        .iter_mut()
        .find(|device| device.route == route_str)
    {
        *existing = fetched.device;
    } else {
        discovery.devices.push(fetched.device);
        sort_devices_leaf_first(&mut discovery.devices, Some(root_route));
    }
    true
}

#[cfg(not(feature = "firmware"))]
fn spawn_upgrade_check(_proxy: Arc<proxy::Interface>, _devices: Vec<DeviceDto>, emitter: Emitter) {
    emitter.debug("firmware upgrade support not compiled in");
}

#[cfg(not(feature = "firmware"))]
fn spawn_upgrade_flash(_proxy: Arc<proxy::Interface>, _route: String, emitter: Emitter) {
    emitter.debug("firmware upgrade support not compiled in");
}

#[cfg(feature = "firmware")]
fn installed_version_text(installed: &firmware::InstalledFirmware) -> String {
    match (&installed.build_date, &installed.hash) {
        (Some(date), Some(hash)) => format!("{date} ({hash})"),
        (Some(date), None) => date.to_string(),
        (None, Some(hash)) => hash.clone(),
        (None, None) => installed.description.clone(),
    }
}

/// Background firmware-availability check. For each discovered device route,
/// queries the installed firmware (`dev.desc`) and compares it against the
/// published GitHub catalog. Emits a single `upgradeStatus` event listing the
/// devices that have a strictly-newer release available. Runs on its own thread
/// (network + RPC) so the streaming loop is never blocked.
#[cfg(feature = "firmware")]
fn spawn_upgrade_check(proxy: Arc<proxy::Interface>, devices: Vec<DeviceDto>, emitter: Emitter) {
    let spawn_error_emitter = emitter.clone();
    let spawned = thread::Builder::new()
        .name("twinleaf-upgrade-check".into())
        .spawn(move || {
            let catalog = firmware::github::GithubCatalog::twinleaf();
            let mut available = Vec::new();

            for device in &devices {
                let Ok(route) = DeviceRoute::from_str(&device.route) else {
                    continue;
                };
                let Ok(port) = proxy.device_rpc(route) else {
                    continue;
                };
                let installed = match firmware::query_installed(&port) {
                    Ok(installed) => installed,
                    Err(err) => {
                        emitter.debug(format!(
                            "upgrade check: dev.desc failed for {}: {err}",
                            device.route
                        ));
                        continue;
                    }
                };
                match firmware::check_for_update(installed.clone(), &catalog) {
                    Ok(report) if report.status == UpdateStatus::UpdateAvailable => {
                        if let Some(latest) = report.latest {
                            available.push(json!({
                                "route": device.route,
                                "deviceName": if device.meta.name.is_empty() {
                                    device.route.clone()
                                } else {
                                    device.meta.name.clone()
                                },
                                "currentVersion": installed_version_text(&installed),
                                "newVersion": latest.date.to_string(),
                                "newHash": latest.short_hash,
                                "filename": latest.filename,
                            }));
                        }
                    }
                    Ok(_) => {}
                    Err(err) => emitter.debug(format!(
                        "upgrade check: comparison failed for {}: {err}",
                        device.route
                    )),
                }
            }

            emitter.emit(&json!({
                "type": "upgradeStatus",
                "available": available,
            }));
        });
    if let Err(err) = spawned {
        spawn_error_emitter.debug(format!("failed to spawn upgrade-check thread: {err}"));
    }
}

/// Background firmware flash for a single device route. Re-derives the latest
/// release, downloads it (cached), and flashes — emitting `upgradeProgress`
/// events for every phase so the UI can show detailed progress. Runs on its own
/// thread because `firmware::flash` blocks for the full upload + settle period.
#[cfg(feature = "firmware")]
fn spawn_upgrade_flash(proxy: Arc<proxy::Interface>, route: String, emitter: Emitter) {
    let spawn_error_emitter = emitter.clone();
    let spawned = thread::Builder::new()
        .name("twinleaf-upgrade-flash".into())
        .spawn(move || {
            let progress = |phase: &str, body: Value| {
                let mut event = json!({
                    "type": "upgradeProgress",
                    "route": route,
                    "phase": phase,
                });
                if let (Value::Object(map), Value::Object(extra)) = (&mut event, body) {
                    map.extend(extra);
                }
                emitter.emit(&event);
            };

            if let Err(message) = run_upgrade_flash(&proxy, &route, &progress) {
                progress("error", json!({ "message": message }));
            }
        });
    if let Err(err) = spawned {
        spawn_error_emitter.debug(format!("failed to spawn upgrade-flash thread: {err}"));
    }
}

#[cfg(feature = "firmware")]
fn run_upgrade_flash(
    proxy: &Arc<proxy::Interface>,
    route: &str,
    progress: &dyn Fn(&str, Value),
) -> Result<(), String> {
    let device_route =
        DeviceRoute::from_str(route).map_err(|_| format!("invalid device route: {route}"))?;
    let port = proxy
        .device_rpc(device_route)
        .map_err(|err| format!("could not open device: {err:?}"))?;

    let installed = firmware::query_installed(&port)
        .map_err(|err| format!("could not read firmware: {err}"))?;
    let catalog = firmware::github::GithubCatalog::twinleaf();
    let report = firmware::check_for_update(installed, &catalog)
        .map_err(|err| format!("could not check for update: {err}"))?;
    let release = report
        .latest
        .ok_or_else(|| "no published firmware available for this device".to_string())?;

    progress(
        "downloading",
        json!({ "newVersion": release.date.to_string(), "filename": release.filename }),
    );
    let firmware_data = match firmware::default_cache_dir() {
        Some(cache_root) => firmware::download_cached(&catalog, &release, &cache_root),
        None => catalog.download(&release),
    }
    .map_err(|err| format!("download failed: {err}"))?;

    firmware::flash(&port, &firmware_data, |event| match event {
        FlashEvent::Stopping => progress("stopping", json!({ "message": "Stopping device" })),
        FlashEvent::Stopped(outcome) => {
            let message = match outcome {
                StopOutcome::Stopped => "Device stopped",
                StopOutcome::AlreadyStopped => "Device already stopped",
                StopOutcome::Unsupported => "Device has no stop command; continuing",
            };
            progress("stopped", json!({ "message": message }));
        }
        FlashEvent::Uploading { chunk, total } => progress(
            "uploading",
            json!({
                "chunk": chunk,
                "total": total,
                "fraction": if total > 0 { chunk as f64 / total as f64 } else { 0.0 },
                "message": format!("Uploading firmware {chunk}/{total}"),
            }),
        ),
        FlashEvent::Committing => {
            progress("committing", json!({ "message": "Committing upgrade" }))
        }
        FlashEvent::Finalizing => progress(
            "finalizing",
            json!({ "message": "Finalizing — keeping the device powered" }),
        ),
        FlashEvent::Complete => {}
    })
    .map_err(|err| format!("flash failed: {err}"))?;

    progress(
        "complete",
        json!({ "message": "Upgrade complete", "fraction": 1.0 }),
    );
    Ok(())
}

/// Fold a route that the `DeviceTree` flagged as newly seen mid-session into
/// the running state — `discovery.devices` (so the sidebar updates),
/// `column_states` (so streams get plotted), and `rpc_index` (so RPCs route
/// correctly). Returns true if a new device was actually added.
///
/// Skips routes we already know about (the root route and the initially-
/// discovered children re-fire `RouteDiscovered` as packets flow). Failures
/// to fetch metadata are logged at debug only — a late-arriving device that
/// can't be reached shouldn't spam the user with errors.
fn add_late_discovered_route(
    proxy: &Arc<proxy::Interface>,
    url: &str,
    route: &DeviceRoute,
    root_route: &DeviceRoute,
    emitter: &Emitter,
    discovery: &mut DeviceDiscoveryResult,
    column_states: &mut HashMap<ColumnKeyDto, ColumnState>,
    rpc_index: &mut HashMap<(String, String), RpcDto>,
) -> bool {
    let route_str = route.to_string();
    if discovery.devices.iter().any(|d| d.route == route_str) {
        return false;
    }

    emitter.debug(format!(
        "route {route} appeared mid-session; fetching metadata"
    ));
    emitter.status(
        "metadata",
        format!("Discovering new device on route {route}"),
    );
    let fetched = match panic::catch_unwind(AssertUnwindSafe(|| {
        fetch_device(proxy, url, route, None, emitter, false)
    })) {
        Ok(Ok(fetched)) => fetched,
        Ok(Err(err)) => {
            emitter.debug(format!("late discovery of {route} skipped: {err}"));
            return false;
        }
        Err(err) => {
            emitter.debug(format!(
                "late discovery of {route} panicked: {}",
                panic_message(err)
            ));
            return false;
        }
    };

    if !fetched.rpc_metadata_complete {
        discovery.incomplete_rpc_routes.insert(route.clone());
    }

    for stream in &fetched.device.streams {
        for column in &stream.columns {
            let label = format!(
                "{} {}.{}",
                fetched.device.meta.name, stream.name, column.name
            );
            column_states.entry(column.key.clone()).or_insert_with(|| {
                ColumnState::new(label, column.units.clone(), stream.effective_sampling_rate)
            });
        }
    }
    for rpc in &fetched.device.rpcs {
        rpc_index.insert(
            (fetched.device.route.clone(), rpc.name.clone()),
            rpc.clone(),
        );
    }
    discovery.devices.push(fetched.device);
    sort_devices_leaf_first(&mut discovery.devices, Some(root_route));
    true
}

fn recover_incomplete_rpc_metadata(
    proxy: &Arc<proxy::Interface>,
    discovery: &mut DeviceDiscoveryResult,
    emitter: &Emitter,
) -> bool {
    let routes: Vec<DeviceRoute> = discovery.incomplete_rpc_routes.iter().cloned().collect();
    let mut metadata_changed = false;

    for route in routes {
        let route_text = route.to_string();
        let Some(device_index) = discovery
            .devices
            .iter()
            .position(|device| device.route == route_text)
        else {
            discovery.incomplete_rpc_routes.remove(&route);
            continue;
        };

        let Ok(port) = proxy.device_rpc(route.clone()) else {
            emitter.debug(format!(
                "RPC metadata recovery could not open RPC port for route {route}"
            ));
            continue;
        };

        let RpcFetchResult { rpcs, complete } = fetch_rpcs(port, &route, emitter);
        if !rpc_lists_equivalent(&discovery.devices[device_index].rpcs, &rpcs) {
            discovery.devices[device_index].rpcs = rpcs;
            metadata_changed = true;
        }

        if complete {
            discovery.incomplete_rpc_routes.remove(&route);
            emitter.debug(format!("RPC metadata recovery complete for route {route}"));
        }
    }

    metadata_changed
}

fn rpc_lists_equivalent(lhs: &[RpcDto], rhs: &[RpcDto]) -> bool {
    lhs.len() == rhs.len()
        && lhs.iter().zip(rhs.iter()).all(|(left, right)| {
            left.name == right.name
                && left.size == right.size
                && left.permissions == right.permissions
                && left.arg_type == right.arg_type
                && left.readable == right.readable
                && left.writable == right.writable
                && left.persistent == right.persistent
                && left.unknown == right.unknown
        })
}

fn handle_monitor_packet(
    mut packet: tio::Packet,
    root_route: &DeviceRoute,
    logger: &mut PacketLogger,
    latest_stream_timestamp_by_route: &HashMap<DeviceRoute, f64>,
    emitter: &Emitter,
) {
    // The port's scope guarantees the route resolves; a failure would mean a
    // packet from outside the subtree, which is safe to drop.
    let Ok(absolute) = root_route.absolute_route(&packet.routing) else {
        return;
    };
    packet.routing = absolute;
    emit_tio_log_message(
        &packet,
        latest_stream_timestamp_by_route
            .get(&packet.routing)
            .copied(),
        emitter,
    );
    logger.write_packet(packet, emitter);
}

/// Drain everything queued on the raw monitor port. Returns the packet count
/// and whether the port is still alive; a dead port must not be drained again
/// or its error would repeat every tick.
fn drain_packet_monitor_port(
    port: &proxy::Port,
    root_route: &DeviceRoute,
    logger: &mut PacketLogger,
    latest_stream_timestamp_by_route: &HashMap<DeviceRoute, f64>,
    emitter: &Emitter,
) -> (usize, bool) {
    let mut packet_count = 0;
    loop {
        match port.try_recv() {
            Ok(packet) => {
                handle_monitor_packet(
                    packet,
                    root_route,
                    logger,
                    latest_stream_timestamp_by_route,
                    emitter,
                );
                packet_count += 1;
            }
            Err(proxy::RecvError::WouldBlock) => return (packet_count, true),
            Err(err) => {
                emitter.error(format!("Raw logging port failed: {err:?}"));
                return (packet_count, false);
            }
        }
    }
}

fn emit_tio_log_message(packet: &tio::Packet, timestamp_seconds: Option<f64>, emitter: &Emitter) {
    let Payload::LogMessage(log) = &packet.payload else {
        return;
    };
    let message = log.message.trim_matches(char::from(0)).trim().to_string();
    if message.is_empty() {
        return;
    }
    let timestamp_seconds = timestamp_seconds
        .filter(|seconds| seconds.is_finite() && *seconds >= 0.0)
        .unwrap_or_else(|| f64::from(log.data) / 1_000.0);
    emitter.emit(&json!({
        "type": "logMessage",
        "route": packet.routing.to_string(),
        "timestampSeconds": timestamp_seconds,
        "message": message
    }));
}

fn spawn_proxy_status_forwarder(
    url: String,
    proxy_status_rx: Receiver<proxy::Event>,
    session_status_tx: Sender<proxy::Event>,
    emitter: Emitter,
) {
    thread::Builder::new()
        .name("proxy-status-forwarder".into())
        .spawn(move || {
            for event in proxy_status_rx {
                emitter.debug(format!("proxy event from {url}: {event:?}"));
                let _ = session_status_tx.send(event);
            }
            emitter.debug(format!("proxy status channel ended for {url}"));
        })
        .expect("failed to spawn proxy status forwarder");
}

fn is_retryable_connect_url(url: &str) -> bool {
    url.starts_with("udp://") || url.starts_with("tcp://")
}

fn collect_startup_commands(
    command_rx: &Receiver<SessionCommand>,
    pending_commands: &mut VecDeque<SessionCommand>,
    emitter: &Emitter,
) -> bool {
    for command in command_rx.try_iter() {
        match command {
            SessionCommand::Stop => {
                emitter.debug("stop requested while waiting for startup");
                emitter.status("disconnected", "Stopped before connection completed");
                return false;
            }
            other => pending_commands.push_back(other),
        }
    }
    true
}

fn sleep_with_startup_cancel(
    duration: Duration,
    command_rx: &Receiver<SessionCommand>,
    pending_commands: &mut VecDeque<SessionCommand>,
    emitter: &Emitter,
) -> bool {
    let deadline = Instant::now() + duration;
    while Instant::now() < deadline {
        if !collect_startup_commands(command_rx, pending_commands, emitter) {
            return false;
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        thread::sleep(remaining.min(Duration::from_millis(50)));
    }
    collect_startup_commands(command_rx, pending_commands, emitter)
}

fn wait_for_proxy_connection(
    status_rx: &Receiver<proxy::Event>,
    command_rx: &Receiver<SessionCommand>,
    pending_commands: &mut VecDeque<SessionCommand>,
    emitter: &Emitter,
    timeout: Duration,
    retry_transient_failures: bool,
) -> bool {
    let deadline = Instant::now() + timeout;
    emitter.debug(format!(
        "waiting up to {:.1}s for proxy connection",
        timeout.as_secs_f64()
    ));
    let mut last_wait_log = Instant::now();

    while Instant::now() < deadline {
        if !collect_startup_commands(command_rx, pending_commands, emitter) {
            return false;
        }

        match status_rx.recv_timeout(Duration::from_millis(250)) {
            Ok(proxy::Event::SensorConnected) | Ok(proxy::Event::SensorReconnected) => {
                emitter.debug("proxy reported sensor connected");
                emitter.status("connected", "Sensor connection established");
                return true;
            }
            Ok(proxy::Event::FailedToConnect) => {
                emitter.debug("proxy reported FailedToConnect");
                if !retry_transient_failures {
                    emitter.error("Twinleaf proxy failed to connect");
                    return false;
                }
                emitter.emit(&json!({
                    "type": "proxyEvent",
                    "event": "FailedToConnect"
                }));
            }
            Ok(proxy::Event::FailedToReconnect) => {
                emitter.debug("proxy reported FailedToReconnect");
                if !retry_transient_failures {
                    emitter.error("Twinleaf proxy failed to reconnect");
                    return false;
                }
                emitter.emit(&json!({
                    "type": "proxyEvent",
                    "event": "FailedToReconnect"
                }));
            }
            Ok(proxy::Event::FatalError(err)) => {
                emitter.debug(format!("proxy fatal error: {err:?}"));
                emitter.error(format!("Twinleaf proxy fatal error: {err:?}"));
                return false;
            }
            Ok(event) => {
                emitter.debug(format!("proxy event while connecting: {event:?}"));
                emitter.emit(&json!({
                    "type": "proxyEvent",
                    "event": format!("{event:?}")
                }));
            }
            Err(channel::RecvTimeoutError::Timeout) => {
                if last_wait_log.elapsed() >= Duration::from_secs(1) {
                    emitter.debug("still waiting for proxy connection...");
                    last_wait_log = Instant::now();
                }
            }
            Err(channel::RecvTimeoutError::Disconnected) => {
                emitter.debug("proxy status channel disconnected while connecting");
                emitter.error("Twinleaf proxy status channel disconnected");
                return false;
            }
        }
    }

    emitter.debug("timed out waiting for proxy connection");
    emitter.error("Timed out waiting for Twinleaf proxy connection");
    false
}

#[derive(Debug)]
struct DeviceDiscoveryResult {
    devices: Vec<DeviceDto>,
    incomplete_rpc_routes: HashSet<DeviceRoute>,
}

#[derive(Debug)]
struct FetchedDevice {
    device: DeviceDto,
    rpc_metadata_complete: bool,
}

#[derive(Debug)]
struct RpcFetchResult {
    rpcs: Vec<RpcDto>,
    complete: bool,
}

fn discover_devices_until_available(
    proxy: &Arc<proxy::Interface>,
    url: &str,
    root_route: &DeviceRoute,
    command_rx: &Receiver<SessionCommand>,
    pending_commands: &mut VecDeque<SessionCommand>,
    emitter: &Emitter,
    timeout: Duration,
) -> Option<DeviceDiscoveryResult> {
    let deadline = Instant::now() + timeout;
    let mut attempt = 1usize;

    while Instant::now() < deadline {
        if !collect_startup_commands(command_rx, pending_commands, emitter) {
            return None;
        }

        emitter.status(
            "discovering",
            format!("Discovering devices on {url} (attempt {attempt})"),
        );
        let discovery = discover_devices(proxy, url, root_route, emitter, false);
        if !discovery.devices.is_empty() {
            return Some(discovery);
        }

        emitter.debug(format!(
            "device metadata not available yet on attempt {attempt}; retrying"
        ));
        attempt += 1;
        if !sleep_with_startup_cancel(
            CONNECTION_METADATA_RETRY_DELAY,
            command_rx,
            pending_commands,
            emitter,
        ) {
            return None;
        }
    }

    emitter.error("Timed out waiting for Twinleaf device metadata");
    None
}

fn discover_devices(
    proxy: &Arc<proxy::Interface>,
    url: &str,
    root_route: &DeviceRoute,
    emitter: &Emitter,
    report_errors: bool,
) -> DeviceDiscoveryResult {
    // A short-lived tree over the whole topology; `named_routes` observes
    // heartbeats passively and pairs each route with its dev.name over the
    // same port. It is a client port on the in-process proxy Interface, not
    // a second connection to the hardware.
    let mut named_routes = Vec::new();
    match proxy.tree_full() {
        Ok(discovery_port) => {
            emitter.debug("opened tree_full discovery port");
            let mut scan = DeviceTree::new(discovery_port, DeviceRoute::root());
            named_routes = scan.named_routes(Duration::from_secs(2));
            for named in &named_routes {
                emitter.debug(format!(
                    "discovered route {} ({})",
                    named.route,
                    named.name.as_deref().unwrap_or("unnamed")
                ));
            }
        }
        Err(_) => emitter.debug("failed to open tree_full discovery port"),
    }

    if named_routes.is_empty() {
        emitter.debug(format!(
            "no discovered routes; falling back to requested route {root_route}"
        ));
        named_routes.push(NamedRoute {
            route: *root_route,
            name: None,
        });
    }

    let mut devices = Vec::new();
    let mut incomplete_rpc_routes = HashSet::new();
    for named in named_routes {
        let route = named.route;
        emitter.status("metadata", format!("Fetching metadata for route {route}"));
        emitter.debug(format!("fetching device metadata/RPCs for route {route}"));
        match panic::catch_unwind(AssertUnwindSafe(|| {
            fetch_device(
                proxy,
                url,
                &route,
                named.name.as_deref(),
                emitter,
                report_errors,
            )
        })) {
            Ok(Ok(fetched)) => {
                if !fetched.rpc_metadata_complete {
                    incomplete_rpc_routes.insert(route.clone());
                }
                devices.push(fetched.device);
            }
            Ok(Err(err)) => emit_metadata_issue(
                emitter,
                report_errors,
                format!("Failed to fetch metadata for route {}: {err}", route),
            ),
            Err(err) => emit_metadata_issue(
                emitter,
                report_errors,
                format!(
                    "Twinleaf parser panic while fetching metadata for route {}: {}",
                    route,
                    panic_message(err)
                ),
            ),
        }
    }
    sort_devices_leaf_first(&mut devices, Some(root_route));
    DeviceDiscoveryResult {
        devices,
        incomplete_rpc_routes,
    }
}

fn emit_metadata_issue(emitter: &Emitter, report_errors: bool, message: String) {
    if report_errors {
        emitter.error(message);
    } else {
        emitter.debug(message);
    }
}

fn sort_devices_leaf_first(devices: &mut [DeviceDto], root_route: Option<&DeviceRoute>) {
    let root_route = root_route.map(|route| route.to_string());
    sort_devices_leaf_first_with_root(devices, root_route.as_deref());
}

fn sort_devices_leaf_first_with_root(devices: &mut [DeviceDto], root_route: Option<&str>) {
    let routes: Vec<_> = devices.iter().map(|device| device.route.clone()).collect();
    devices.sort_by(|a, b| {
        let a_is_hub = is_hub_route(&a.route, root_route);
        let b_is_hub = is_hub_route(&b.route, root_route);
        a_is_hub
            .cmp(&b_is_hub)
            .then_with(|| {
                is_parent_route(&a.route, &routes).cmp(&is_parent_route(&b.route, &routes))
            })
            .then_with(|| route_depth(&b.route).cmp(&route_depth(&a.route)))
            .then_with(|| a.route.cmp(&b.route))
    });
}

fn is_hub_route(route: &str, root_route: Option<&str>) -> bool {
    route == "/" || root_route.is_some_and(|root_route| route == root_route)
}

fn is_parent_route(route: &str, routes: &[String]) -> bool {
    if route == "/" {
        return routes.iter().any(|other| other != route);
    }

    let route = route.trim_end_matches('/');
    if route.is_empty() {
        return false;
    }

    let prefix = format!("{route}/");
    routes
        .iter()
        .any(|other| other != route && other.starts_with(&prefix))
}

fn route_depth(route: &str) -> usize {
    route
        .trim_matches('/')
        .split('/')
        .filter(|part| !part.is_empty())
        .count()
}

fn payload_name(payload: &Payload) -> &'static str {
    match payload {
        Payload::LogMessage(_) => "LogMessage",
        Payload::RpcRequest(_) => "RpcRequest",
        Payload::RpcReply(_) => "RpcReply",
        Payload::RpcError(_) => "RpcError",
        Payload::LegacyTimebaseUpdate(_) => "LegacyTimebaseUpdate",
        Payload::LegacySourceUpdate(_) => "LegacySourceUpdate",
        Payload::LegacyStreamUpdate(_) => "LegacyStreamUpdate",
        Payload::Heartbeat(_) => "Heartbeat",
        Payload::Metadata(_) => "Metadata",
        Payload::Settings(_) => "Settings",
        Payload::LegacyStreamData(_) => "LegacyStreamData",
        Payload::StreamData(_) => "StreamData",
        Payload::ProxyStatus(_) => "ProxyStatus",
        Payload::RpcUpdate(_) => "RpcUpdate",
        Payload::Unknown(_) => "Unknown",
    }
}

fn panic_message(err: Box<dyn std::any::Any + Send>) -> String {
    if let Some(message) = err.downcast_ref::<String>() {
        message.clone()
    } else if let Some(message) = err.downcast_ref::<&'static str>() {
        (*message).to_string()
    } else {
        "unknown panic payload".to_string()
    }
}

fn fetch_device(
    proxy: &Arc<proxy::Interface>,
    url: &str,
    route: &DeviceRoute,
    fallback_name: Option<&str>,
    emitter: &Emitter,
    report_errors: bool,
) -> Result<FetchedDevice, String> {
    let rpc_fetch = match proxy.device_rpc(route.clone()) {
        Ok(port) => fetch_rpcs(port, route, emitter),
        Err(err) => {
            emit_metadata_issue(
                emitter,
                report_errors,
                format!("Failed to open RPC port for route {route}: {err:?}"),
            );
            RpcFetchResult {
                rpcs: Vec::new(),
                complete: false,
            }
        }
    };

    let (meta, streams, full_metadata) =
        match panic::catch_unwind(AssertUnwindSafe(|| fetch_stream_metadata(proxy, route))) {
            Ok(Ok(metadata)) => {
                let (meta, streams) = metadata_to_stream_dtos(route, &metadata);
                (meta, streams, Some(metadata))
            }
            Ok(Err(err)) => {
                emit_metadata_issue(
                    emitter,
                    report_errors,
                    format!("Failed to fetch stream metadata for route {route}: {err}"),
                );
                (fallback_device_meta(route, fallback_name), Vec::new(), None)
            }
            Err(err) => {
                emit_metadata_issue(
                    emitter,
                    report_errors,
                    format!(
                    "Twinleaf parser panic while fetching stream metadata for route {route}: {}",
                    panic_message(err)
                ),
                );
                (fallback_device_meta(route, fallback_name), Vec::new(), None)
            }
        };

    if streams.is_empty() && rpc_fetch.rpcs.is_empty() {
        return Err("No stream metadata or RPC metadata returned".to_string());
    }

    Ok(FetchedDevice {
        device: DeviceDto {
            url: url.to_string(),
            route: route.to_string(),
            meta,
            streams,
            rpcs: rpc_fetch.rpcs,
            full_metadata,
        },
        rpc_metadata_complete: rpc_fetch.complete,
    })
}

fn fallback_device_meta(route: &DeviceRoute, fallback_name: Option<&str>) -> DeviceMetaDto {
    DeviceMetaDto {
        serial_number: String::new(),
        firmware_hash: String::new(),
        n_streams: 0,
        session_id: 0,
        name: fallback_name
            .filter(|name| !name.is_empty())
            .map(str::to_string)
            .unwrap_or_else(|| route.to_string()),
    }
}

fn fetch_stream_metadata(
    proxy: &Arc<proxy::Interface>,
    route: &DeviceRoute,
) -> Result<DeviceMetadataSnapshot, String> {
    let mut data_device = Device::open(proxy, route.clone()).map_err(|err| format!("{err:?}"))?;
    data_device.get_metadata().map_err(|err| format!("{err:?}"))
}

fn metadata_to_device_dto(
    url: String,
    route: &DeviceRoute,
    metadata: &DeviceMetadataSnapshot,
    rpcs: Vec<RpcDto>,
) -> DeviceDto {
    let (meta, streams) = metadata_to_stream_dtos(route, metadata);
    DeviceDto {
        url,
        route: route.to_string(),
        meta,
        streams,
        rpcs,
        full_metadata: Some(metadata.clone()),
    }
}

fn metadata_to_stream_dtos(
    route: &DeviceRoute,
    metadata: &DeviceMetadataSnapshot,
) -> (DeviceMetaDto, Vec<StreamDto>) {
    let meta = DeviceMetaDto {
        serial_number: metadata.device.serial_number.clone(),
        firmware_hash: metadata.device.firmware_hash.clone(),
        n_streams: metadata.device.n_streams,
        session_id: metadata.device.session_id,
        name: metadata.device.name.clone(),
    };

    let mut streams = Vec::new();
    let mut stream_ids: Vec<u8> = metadata.streams.keys().copied().collect();
    stream_ids.sort_unstable();

    for stream_id in stream_ids {
        let stream = metadata.streams.get(&stream_id).unwrap();
        let decimation = if stream.segment.decimation == 0 {
            1.0
        } else {
            stream.segment.decimation as f64
        };
        let effective_sampling_rate = stream.segment.sampling_rate as f64 / decimation;

        let mut columns: Vec<ColumnDto> = stream
            .columns
            .iter()
            .map(|column| ColumnDto {
                key: ColumnKeyDto::raw(route.to_string(), stream.stream.stream_id, column.index),
                name: column.name.clone(),
                units: column.units.clone(),
                data_type: format!("{:?}", column.data_type),
                description: column.description.clone(),
                display_value: None,
            })
            .collect();
        columns.sort_by_key(|column| column.key.column_index);

        streams.push(StreamDto {
            stream_id: stream.stream.stream_id,
            name: stream.stream.name.clone(),
            n_columns: stream.stream.n_columns,
            sample_size: stream.stream.sample_size,
            effective_sampling_rate,
            columns,
        });
    }

    (meta, streams)
}

fn fetch_rpcs(port: proxy::Port, route: &DeviceRoute, emitter: &Emitter) -> RpcFetchResult {
    emitter.debug(format!("fetching RPC list for route {route}"));
    let client = RpcClient::new(port);
    let registry = match retry_rpc_metadata_request(route, "rpc registry", emitter, || {
        client
            .registry(route)
            .map_err(RpcMetadataRequestError::Registry)
    }) {
        Ok(registry) => registry,
        Err(err) => {
            if matches!(err, RpcMetadataRequestError::Panic(_)) {
                emitter.error(format!(
                    "Twinleaf parser panic while listing RPCs for route {route}: {err}"
                ));
            } else {
                emitter.debug(format!(
                    "rpc registry fetch failed for route {route}: {err}"
                ));
            }
            return RpcFetchResult {
                rpcs: Vec::new(),
                complete: false,
            };
        }
    };

    let mut rpcs: Vec<RpcDto> = registry
        .iter()
        .map(|descriptor| RpcDto {
            route: route.to_string(),
            name: descriptor.full_name.clone(),
            size: rpc_size(descriptor),
            permissions: rpc_permissions(descriptor),
            arg_type: rpc_arg_type(descriptor),
            readable: rpc_readable(descriptor),
            writable: descriptor.meta.flags().contains(RpcMetaFlags::WRITABLE),
            persistent: descriptor.meta.is_persistent(),
            unknown: rpc_unknown(descriptor),
            value: None,
        })
        .collect();

    rpcs.sort_by(|a, b| a.name.cmp(&b.name));
    emitter.debug(format!("loaded {} RPC(s) for route {route}", rpcs.len()));
    RpcFetchResult {
        rpcs,
        complete: true,
    }
}

#[derive(Debug)]
enum RpcMetadataRequestError {
    Registry(RpcRegistryError),
    Panic(String),
}

impl std::fmt::Display for RpcMetadataRequestError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Registry(err) => write!(formatter, "{err:?}"),
            Self::Panic(err) => formatter.write_str(err),
        }
    }
}

impl RpcMetadataRequestError {
    fn is_retryable(&self) -> bool {
        match self {
            Self::Registry(RpcRegistryError::DeviceRpcError(err)) => match err {
                proxy::RpcError::ResponseLost | proxy::RpcError::Timeout => true,
                proxy::RpcError::DeviceError(payload) => {
                    matches!(payload.error, tio::proto::RpcErrorCode::Timeout)
                }
                _ => false,
            },
            Self::Registry(_) | Self::Panic(_) => false,
        }
    }
}

fn retry_rpc_metadata_request<T, F>(
    route: &DeviceRoute,
    label: &str,
    emitter: &Emitter,
    mut request: F,
) -> Result<T, RpcMetadataRequestError>
where
    F: FnMut() -> Result<T, RpcMetadataRequestError>,
{
    for attempt in 1..=RPC_METADATA_RETRY_ATTEMPTS {
        let result = panic::catch_unwind(AssertUnwindSafe(|| request()));
        match result {
            Ok(Ok(value)) => {
                if attempt > 1 {
                    emitter.debug(format!(
                        "{label} for route {route} succeeded on attempt {attempt}"
                    ));
                }
                return Ok(value);
            }
            Ok(Err(err)) => {
                if attempt == RPC_METADATA_RETRY_ATTEMPTS || !err.is_retryable() {
                    return Err(err);
                }
                emitter.debug(format!(
                    "{label} for route {route} failed on attempt {attempt}/{RPC_METADATA_RETRY_ATTEMPTS}: {err}; retrying"
                ));
            }
            Err(err) => return Err(RpcMetadataRequestError::Panic(panic_message(err))),
        }
        thread::sleep(RPC_METADATA_RETRY_DELAY);
    }

    unreachable!("retry loop must either return a value or the last error")
}

/// Fold one parsed log batch into the playback ingestion state.
#[allow(clippy::too_many_arguments)]
fn ingest_log_batch(
    batch: &SampleBatch,
    column_states: &mut HashMap<ColumnKeyDto, ColumnState>,
    active_columns: &HashSet<ColumnKeyDto>,
    plot_panes: &[PlotPaneConfig],
    recording_start: &mut Option<f64>,
    time_reference_start: &mut Option<f64>,
    latest_stream_timestamp_by_route: &mut HashMap<DeviceRoute, f64>,
    samples: &mut usize,
) {
    *samples += batch.len();
    if let Some(first_row) = batch.row(0) {
        let batch_start = first_row.timestamp_begin();
        if batch_start.is_finite() {
            *recording_start = Some(
                recording_start
                    .map(|start| start.min(batch_start))
                    .unwrap_or(batch_start),
            );
        }
    }
    if let Some(&batch_end) = batch.timestamps().last() {
        if batch_end.is_finite() {
            latest_stream_timestamp_by_route.insert(batch.route(), batch_end);
        }
    }
    *time_reference_start = earliest_time(*time_reference_start, batch_time_reference_start(batch));
    process_batch(
        batch,
        column_states,
        active_columns,
        plot_panes,
        f64::INFINITY,
        None,
    );
}

fn load_log_file(path: &str, emitter: &Emitter) -> Result<PlaybackSession, String> {
    emitter.status("loading", format!("Loading log file {path}"));
    let log = LogFile::open(Path::new(path)).map_err(|err| err.to_string())?;
    if log.is_empty() {
        return Err("Log file is empty".to_string());
    }

    let mut parser = PacketParser::new(DeviceRoute::root(), false).with_batch_rows(4096);
    let mut routes_seen: HashSet<DeviceRoute> = HashSet::new();
    let mut column_states: HashMap<ColumnKeyDto, ColumnState> = HashMap::new();
    let active_columns = HashSet::new();
    let view = ViewConfig::default();
    let plot_panes = default_plot_panes(&view);
    let mut packets = 0usize;
    let mut samples = 0usize;
    let mut recording_start: Option<f64> = None;
    let mut time_reference_start: Option<f64> = None;
    let mut latest_stream_timestamp_by_route: HashMap<DeviceRoute, f64> = HashMap::new();

    let mut packet_iter = log.packets();
    loop {
        let packet = match packet_iter.next() {
            Some(Ok(packet)) => packet,
            Some(Err(err)) => {
                emitter.debug(format!(
                    "stopped log parsing at byte {} of {}: {err:?}",
                    packet_iter.position(),
                    log.len()
                ));
                break;
            }
            None => break,
        };
        packets += 1;

        let route = packet.routing;
        emit_tio_log_message(
            &packet,
            latest_stream_timestamp_by_route.get(&route).copied(),
            emitter,
        );
        routes_seen.insert(route);
        if let Err(err) = parser.push_packet(&packet) {
            emitter.debug(format!("rejected log packet on {route}: {err}"));
        }
        while let Some(batch) = parser.pop_batch() {
            ingest_log_batch(
                &batch,
                &mut column_states,
                &active_columns,
                &plot_panes,
                &mut recording_start,
                &mut time_reference_start,
                &mut latest_stream_timestamp_by_route,
                &mut samples,
            );
        }
    }
    parser.flush();
    while let Some(batch) = parser.pop_batch() {
        ingest_log_batch(
            &batch,
            &mut column_states,
            &active_columns,
            &plot_panes,
            &mut recording_start,
            &mut time_reference_start,
            &mut latest_stream_timestamp_by_route,
            &mut samples,
        );
    }

    let mut devices = Vec::new();
    let url = format!("file://{path}");
    for route in parser.routes() {
        match parser.metadata(route) {
            Some(metadata) => {
                devices.push(metadata_to_device_dto(
                    url.clone(),
                    &route,
                    &metadata,
                    Vec::new(),
                ));
            }
            None => {
                if routes_seen.contains(&route) {
                    emitter.debug(format!(
                        "log route {route} did not include complete metadata"
                    ));
                }
            }
        }
    }
    sort_devices_leaf_first(&mut devices, None);

    if devices.is_empty() {
        return Err("Log did not include complete stream metadata".to_string());
    }

    if data_range(&column_states).is_none() {
        return Err("Log did not include parseable sample data".to_string());
    }

    emitter.debug(format!(
        "loaded log file {path}: packets={packets}, samples={samples}, devices={}",
        devices.len()
    ));

    Ok(PlaybackSession::new(
        devices,
        column_states,
        recording_start,
        time_reference_start,
    ))
}

#[derive(Debug, Clone, Copy)]
struct ExportSummary {
    rows: usize,
    bytes: u64,
}

fn export_log_file(
    source_path: &str,
    output_path: &str,
    format: ExportFormat,
    emitter: &Emitter,
) -> Result<ExportSummary, String> {
    let output_path = Path::new(output_path);

    // Write straight to the destination the user picked in the save panel.
    //
    // Staging through a sibling temp file and renaming it into place does not
    // work under the App Sandbox: the user-selected read/write grant covers the
    // chosen file itself, not arbitrary neighbouring paths in that directory,
    // so creating ".<name>.<pid>.tmp" (or renaming it over the destination) is
    // denied. The export then failed while the empty placeholder the save panel
    // had already created stayed behind — a completely blank CSV.
    let result = match format {
        ExportFormat::Csv => export_log_csv(source_path, output_path, emitter),
        ExportFormat::Hdf5 => export_log_hdf5(source_path, output_path, emitter),
    };

    match result {
        Ok(mut summary) => {
            summary.bytes = std::fs::metadata(output_path)
                .map(|metadata| metadata.len())
                .unwrap_or(0);
            Ok(summary)
        }
        Err(err) => {
            // Writing in place means a failure can leave a partial file (for
            // CSV, the header alone). Truncate it so a failed export never
            // looks like a successful one; the save panel had already emptied
            // this file before we were called, so nothing is lost.
            let _ = File::create(output_path);
            Err(err)
        }
    }
}

fn export_log_csv(
    source_path: &str,
    output_path: &Path,
    emitter: &Emitter,
) -> Result<ExportSummary, String> {
    let log = LogFile::open(Path::new(source_path)).map_err(|err| err.to_string())?;
    if log.is_empty() {
        return Err("Log file is empty".to_string());
    }

    let file = File::create(output_path).map_err(|err| err.to_string())?;
    let mut writer = BufWriter::new(file);
    write_csv_record(
        &mut writer,
        &[
            "route",
            "device",
            "session_id",
            "stream_id",
            "stream",
            "segment_id",
            "sample_number",
            "time",
            "column_index",
            "column",
            "units",
            "data_type",
            "value",
        ],
    )
    .map_err(|err| err.to_string())?;

    let index = log.scan(DeviceRoute::root(), false);
    let packets = index.summary().packet_count();
    let mut samples = 0usize;
    let mut rows = 0usize;

    for batch in index.batches(4096) {
        let batch = match batch {
            Ok(batch) => batch,
            Err(err) => {
                emitter.debug(format!(
                    "stopped CSV export parsing at byte {} of {}: {err:?}",
                    err.offset(),
                    log.len()
                ));
                break;
            }
        };
        samples += batch.len();
        rows += write_batch_csv_records(&mut writer, &batch).map_err(|err| err.to_string())?;
    }

    writer.flush().map_err(|err| err.to_string())?;
    if samples == 0 {
        return Err("Log did not include parseable sample data".to_string());
    }

    emitter.debug(format!(
        "exported CSV from {source_path}: packets={packets}, samples={samples}, rows={rows}"
    ));
    Ok(ExportSummary { rows, bytes: 0 })
}

fn write_batch_csv_records<W: Write>(writer: &mut W, batch: &SampleBatch) -> io::Result<usize> {
    let route = batch.route().to_string();
    let device = batch.device();
    let stream = batch.stream();
    let session_id = device.session_id.to_string();
    let stream_id = batch.stream_key().stream_id.to_string();
    let segment_id = batch.segment().segment_id.to_string();
    let mut rows = 0usize;

    for row in batch.iter() {
        let sample_number = row.n().to_string();
        let timestamp = format!("{:.17}", row.timestamp_end());
        for (series, value) in batch.schema().iter().zip(row.values()) {
            let metadata = series.metadata();
            let fields = vec![
                route.clone(),
                device.name.clone(),
                session_id.clone(),
                stream_id.clone(),
                stream.name.clone(),
                segment_id.clone(),
                sample_number.clone(),
                timestamp.clone(),
                series.index().to_string(),
                metadata.name.clone(),
                metadata.units.clone(),
                format!("{:?}", metadata.data_type),
                value.to_string(),
            ];
            write_csv_record(writer, &fields)?;
            rows += 1;
        }
    }

    Ok(rows)
}

#[cfg(feature = "hdf5")]
fn export_log_hdf5(
    source_path: &str,
    output_path: &Path,
    emitter: &Emitter,
) -> Result<ExportSummary, String> {
    use twinleaf::data::export::{Hdf5Appender, RunSplitLevel, SplitPolicy};

    let log = LogFile::open(Path::new(source_path)).map_err(|err| err.to_string())?;
    if log.is_empty() {
        return Err("Log file is empty".to_string());
    }

    // The export flow writes into a file the save panel already created (the
    // sandbox grants access to that exact path), so overwriting is confirmed
    // by construction; `with_options` would refuse the existing file.
    let mut writer = Hdf5Appender::with_overwrite_options(
        output_path,
        true,
        false,
        None,
        SplitPolicy::default(),
        RunSplitLevel::default(),
    )
    .map_err(|err| format!("Failed to create HDF5 export: {err:?}"))?;

    let index = log.scan(DeviceRoute::root(), false);
    let packets = index.summary().packet_count();
    let mut samples = 0usize;

    for batch in index.batches(65_536) {
        let batch = match batch {
            Ok(batch) => batch,
            Err(err) => {
                emitter.debug(format!(
                    "stopped HDF5 export parsing at byte {} of {}: {err:?}",
                    err.offset(),
                    log.len()
                ));
                break;
            }
        };
        samples += batch.len();
        writer
            .write_batch(batch)
            .map_err(|err| format!("HDF5 write failed: {err:?}"))?;
    }

    let stats = writer
        .finish()
        .map_err(|err| format!("Failed to finalize HDF5 export: {err:?}"))?;
    if stats.total_samples == 0 {
        return Err("Log did not include parseable sample data".to_string());
    }

    emitter.debug(format!(
        "exported HDF5 from {source_path}: packets={packets}, samples={samples}, streams={}",
        stats.streams_written.len()
    ));
    Ok(ExportSummary {
        rows: stats.total_samples as usize,
        bytes: 0,
    })
}

#[cfg(not(feature = "hdf5"))]
fn export_log_hdf5(
    _source_path: &str,
    _output_path: &Path,
    _emitter: &Emitter,
) -> Result<ExportSummary, String> {
    Err("HDF5 export is not enabled in this build of tio-bridge".to_string())
}

fn write_csv_record<W, S>(writer: &mut W, fields: &[S]) -> io::Result<()>
where
    W: Write,
    S: AsRef<str>,
{
    for (index, field) in fields.iter().enumerate() {
        if index > 0 {
            writer.write_all(b",")?;
        }
        write_csv_field(writer, field.as_ref())?;
    }
    writer.write_all(b"\n")
}

fn write_csv_field<W: Write>(writer: &mut W, value: &str) -> io::Result<()> {
    let needs_quotes = value
        .bytes()
        .any(|byte| matches!(byte, b',' | b'"' | b'\n' | b'\r'));
    if !needs_quotes {
        return writer.write_all(value.as_bytes());
    }

    writer.write_all(b"\"")?;
    for byte in value.bytes() {
        if byte == b'"' {
            writer.write_all(b"\"\"")?;
        } else {
            writer.write_all(&[byte])?;
        }
    }
    writer.write_all(b"\"")
}

fn build_column_states(devices: &[DeviceDto]) -> HashMap<ColumnKeyDto, ColumnState> {
    let mut states = HashMap::new();
    for device in devices {
        for stream in &device.streams {
            for column in &stream.columns {
                let label = format!("{} {}.{}", device.meta.name, stream.name, column.name);
                states.insert(
                    column.key.clone(),
                    ColumnState::new(label, column.units.clone(), stream.effective_sampling_rate),
                );
            }
        }
    }
    states
}

fn build_rpc_index(devices: &[DeviceDto]) -> HashMap<(String, String), RpcDto> {
    let mut index = HashMap::new();
    for device in devices {
        for rpc in &device.rpcs {
            index.insert((device.route.clone(), rpc.name.clone()), rpc.clone());
        }
    }
    index
}

fn process_batch(
    batch: &SampleBatch,
    column_states: &mut HashMap<ColumnKeyDto, ColumnState>,
    active_columns: &HashSet<ColumnKeyDto>,
    plot_panes: &[PlotPaneConfig],
    max_window_seconds: f64,
    mut profiler: Option<&mut StreamIngestProfiler>,
) {
    let profile_enabled = profiler.as_ref().is_some_and(|profiler| profiler.enabled);
    let profile_start = profile_enabled.then(Instant::now);
    let mut display_elapsed = Duration::ZERO;
    let mut processed_columns = 0usize;
    let mut active_hits = 0usize;
    let route = batch.route();
    let route_string = route.to_string();
    let stream_id = batch.stream_key().stream_id;
    let segment = batch.segment();
    let effective_rate = segment.sampling_rate as f64 / segment.decimation.max(1) as f64;
    let timestamps = batch.timestamps();
    // Per-column bookkeeping hoists out of the row loop: a batch covers one
    // (route, stream), so key, pane filter, and rate are loop-invariant.
    for series in batch.schema() {
        let key = ColumnKeyDto::raw(route_string.clone(), stream_id, series.index());

        let active_fpcs_panes: Vec<_> = plot_panes
            .iter()
            .filter(|pane| pane_contains_column(pane, &key))
            .filter(|pane| {
                pane.view.mode == PlotMode::Timeseries
                    && pane.view.decimation_method == DecimationMethod::Fpcs
            })
            .map(|pane| (pane.id, pane.view.clone()))
            .collect();
        let is_active = !active_fpcs_panes.is_empty()
            || active_columns.contains(&key)
            || active_columns.iter().any(|active_key| {
                active_key.stream_id == key.stream_id && active_key.column_index == key.column_index
            });
        if is_active {
            active_hits += batch.len();
        }

        let metadata = series.metadata();
        let state = column_states.entry(key.clone()).or_insert_with(|| {
            ColumnState::new(
                format!("{} stream {} column {}", route, stream_id, series.index()),
                metadata.units.clone(),
                effective_rate,
            )
        });
        // Keep the per-column rate in sync with the live segment. A device-side
        // decimation change alters the effective sample rate without new
        // metadata; if the stale rate persists, the FPCS decimation ratio is
        // wrong and the displayed window collapses. `ensure_fpcs_configured`
        // rebuilds the decimator when the resulting ratio changes.
        if effective_rate.is_finite()
            && effective_rate > 0.0
            && (state.sample_rate - effective_rate).abs() > effective_rate * 0.001
        {
            state.sample_rate = effective_rate;
        }
        let mut push_point = |state: &mut ColumnState, point: Point| {
            display_elapsed += state.push_raw_profiled(point, max_window_seconds, profile_enabled);
            processed_columns += 1;
            for (pane_id, view) in &active_fpcs_panes {
                state.process_fpcs_point(*pane_id, view, point);
            }
        };
        match series.values() {
            ColumnArray::F64(values) => {
                for (i, &y) in values.iter().enumerate() {
                    push_point(
                        state,
                        Point {
                            x: timestamps[i],
                            y,
                        },
                    );
                }
            }
            values => {
                for i in 0..values.len() {
                    let Some(y) = values.get(i).try_as_f64() else {
                        continue;
                    };
                    push_point(
                        state,
                        Point {
                            x: timestamps[i],
                            y,
                        },
                    );
                }
            }
        }
    }
    if let (Some(start), Some(profiler)) = (profile_start, profiler.as_deref_mut()) {
        profiler.record(
            start.elapsed(),
            display_elapsed,
            processed_columns,
            active_hits,
            column_states.len(),
            active_columns.len(),
        );
    }
}

/// Seconds of source data behind each derived estimate.
const DERIVED_WINDOW_RANGE: RangeInclusive<f64> = 1.0..=1000.0;
/// Seconds between emitted derived points.
const DERIVED_CADENCE_RANGE: RangeInclusive<f64> = 0.1..=60.0;

fn derived_window_seconds(channel: &DerivedChannelDto) -> f64 {
    if channel.window_seconds.is_finite() {
        channel
            .window_seconds
            .clamp(*DERIVED_WINDOW_RANGE.start(), *DERIVED_WINDOW_RANGE.end())
    } else {
        *DERIVED_WINDOW_RANGE.start()
    }
}

fn derived_cadence_seconds(channel: &DerivedChannelDto) -> f64 {
    if channel.cadence_seconds.is_finite() {
        channel
            .cadence_seconds
            .clamp(*DERIVED_CADENCE_RANGE.start(), *DERIVED_CADENCE_RANGE.end())
    } else {
        *DERIVED_CADENCE_RANGE.start()
    }
}

fn derived_label(source_label: &str, channel: &DerivedChannelDto) -> String {
    match channel.kind() {
        Some(Derivation::NoiseFloor) => format!("{source_label} noise floor"),
        None => source_label.to_string(),
    }
}

/// Advance every derived channel by at most one point per call.
///
/// Points are stamped with the *end* of the window they summarise, on the
/// source's own timestamps — never wall clock. That keeps a derived trace on
/// the same time axis as its source, so it lines up in a shared pane and
/// replays from a log exactly as it ran live.
fn update_derived_channels(
    channels: &[DerivedChannelDto],
    column_states: &mut HashMap<ColumnKeyDto, ColumnState>,
    worker: &mut DerivedWorker,
    max_window_seconds: f64,
) {
    // Land finished work first so the cadence test below sees current
    // timestamps and does not re-request a point already in flight.
    for outcome in worker.take_results() {
        let Some(y) = outcome.y else {
            continue;
        };
        if let Some(state) = column_states.get_mut(&outcome.key) {
            state.push_raw_profiled(Point { x: outcome.x, y }, max_window_seconds, false);
        }
    }

    // Read every source before touching the map: the borrow checker aside,
    // gathering first keeps a channel from observing a state another channel
    // in the same pass just created.
    struct PendingDerivation {
        key: ColumnKeyDto,
        label: String,
        units: String,
        cadence: f64,
        detrend: DetrendMethod,
        sample_rate: f64,
        latest_x: f64,
        points: Vec<Point>,
        has_full_window: bool,
    }

    let mut pending = Vec::new();
    for channel in channels {
        if channel.kind().is_none() {
            continue;
        }
        let source_key = channel.source();
        let Some((_, source)) = resolve_column_state(column_states, &source_key) else {
            continue;
        };
        let Some(latest) = source.raw.back().copied() else {
            continue;
        };
        if !latest.x.is_finite() || source.sample_rate <= 0.0 {
            continue;
        }

        let window = derived_window_seconds(channel);
        let points = source.fft_window_points(window, None);

        // Hold the first point until a full window is available, otherwise
        // the opening estimates carry a different frequency resolution than
        // everything after them. At the raw-buffer cap a full window is
        // unreachable, so the cap itself becomes the bar.
        let wanted = source
            .fft_window_sample_count(window)
            .min(MAX_RAW_POINTS_PER_STREAM);
        let has_full_window = points.len() >= wanted;

        pending.push(PendingDerivation {
            key: channel.key.clone(),
            label: derived_label(&source.label, channel),
            units: channel.units(&source.units),
            cadence: derived_cadence_seconds(channel),
            detrend: channel.detrend,
            sample_rate: source.sample_rate,
            latest_x: latest.x,
            points,
            has_full_window,
        });
    }

    let mut jobs = Vec::new();
    for item in pending {
        let rate = 1.0 / item.cadence;
        let state = column_states
            .entry(item.key.clone())
            .or_insert_with(|| ColumnState::new(item.label.clone(), item.units.clone(), rate));
        // The spec can be retuned while the channel is live; keep the
        // presentation fields in step with it.
        state.label = item.label;
        state.units = item.units;
        state.sample_rate = rate;

        let due = state
            .raw
            .back()
            .map(|point| item.latest_x - point.x >= item.cadence)
            .unwrap_or(true);
        if !due || !item.has_full_window {
            continue;
        }

        jobs.push(DerivedJob {
            key: item.key,
            x: item.latest_x,
            sample_rate: item.sample_rate,
            detrend: item.detrend,
            points: item.points,
        });
    }

    worker.submit(jobs);
}

/// Derive every channel across an already-loaded time range in one pass.
///
/// Used for log playback, where there is no live tick to advance the channel.
/// Runs on the calling thread: it is a one-time cost when a log opens or the
/// derived set changes, not a per-frame one.
fn rebuild_derived_columns_for_range(
    channels: &[DerivedChannelDto],
    column_states: &mut HashMap<ColumnKeyDto, ColumnState>,
    range: Option<(f64, f64)>,
) {
    let Some((start, end)) = range else {
        return;
    };

    for channel in channels {
        if channel.kind().is_none() {
            continue;
        }
        let source_key = channel.source();
        let Some((_, source)) = resolve_column_state(column_states, &source_key) else {
            continue;
        };
        if source.sample_rate <= 0.0 {
            continue;
        }

        let window = derived_window_seconds(channel);
        let cadence = derived_cadence_seconds(channel);
        let label = derived_label(&source.label, channel);
        let units = channel.units(&source.units);
        let sample_rate = source.sample_rate;
        let detrend = channel.detrend;

        // The first estimate needs a full window behind it, same rule as live.
        let mut derived = Vec::new();
        let mut x = start + window;
        while x <= end {
            let points = source.fft_window_points(window, Some(x));
            if points.len() >= source.fft_window_sample_count(window) {
                let spectrum = fft_points(&points, sample_rate, detrend);
                if let Some(y) = estimate_white_noise_floor(&spectrum) {
                    derived.push(Point { x, y });
                }
            }
            x += cadence;
        }

        if derived.is_empty() {
            continue;
        }

        let mut state = ColumnState::new(label, units, 1.0 / cadence);
        for point in derived {
            state.push_raw_profiled(point, f64::INFINITY, false);
        }
        column_states.insert(channel.key.clone(), state);
    }
}

fn hydrate_fpcs(
    column_states: &mut HashMap<ColumnKeyDto, ColumnState>,
    plot_panes: &[PlotPaneConfig],
    emitter: &Emitter,
) {
    let pane_ids = active_fpcs_pane_ids(plot_panes);
    for state in column_states.values_mut() {
        state.retain_fpcs_panes(&pane_ids);
    }

    for pane in plot_panes {
        let view = &pane.view;
        if view.mode != PlotMode::Timeseries {
            continue;
        }

        if view.decimation_method != DecimationMethod::Fpcs {
            emitter.debug(format!(
                "pane {} timeseries decimation disabled; emitting raw points for {:.1}s window",
                pane.id, view.window_seconds
            ));
            continue;
        }

        let active_columns = pane_columns_set(pane);
        let max_sampling_rate = active_columns
            .iter()
            .filter_map(|key| column_states.get(key).map(|state| state.sample_rate))
            .fold(0.0, f64::max)
            .max(1.0);

        let target_points = target_plot_points(view);
        let ratio = fpcs_ratio(max_sampling_rate, view);
        emitter.debug(format!(
            "FPCS hydrate pane={}: active={}, width={}px, resolution={}%, target_points={}, max_sr={:.3}Hz, window={:.1}s, ratio={}",
            pane.id,
            active_columns.len(),
            view.plot_width_pixels,
            view.resolution_multiplier,
            target_points,
            max_sampling_rate,
            view.window_seconds,
            ratio
        ));

        for key in &active_columns {
            let Some(data_key) = resolve_data_key(column_states, key) else {
                continue;
            };
            if let Some(state) = column_states.get_mut(&data_key) {
                // Rebuild (not just ensure) so a column re-entering a pane gets
                // a fresh ring from the continuous raw buffer — no gap across
                // the interval it was unselected.
                state.rebuild_fpcs(pane.id, view);
            }
        }
    }
}

fn target_plot_points(view: &ViewConfig) -> usize {
    let width = view.plot_width_pixels.clamp(64, 8_192);
    let multiplier = view.resolution_multiplier.clamp(20, 200) as f64 / 100.0;
    ((width as f64 * multiplier).round() as usize).clamp(64, 8_192)
}

fn fpcs_ratio(sample_rate: f64, view: &ViewConfig) -> usize {
    let window_samples = sample_rate.max(1.0) * view.window_seconds.max(1e-6);
    ((2.0 * window_samples) / target_plot_points(view) as f64)
        .ceil()
        .max(1.0) as usize
}

fn default_plot_panes(view: &ViewConfig) -> Vec<PlotPaneConfig> {
    vec![PlotPaneConfig {
        id: 0,
        view: view.clone(),
        columns: Vec::new(),
    }]
}

fn pane_columns_set(pane: &PlotPaneConfig) -> HashSet<ColumnKeyDto> {
    pane.columns.iter().cloned().collect()
}

fn active_columns_for_panes(plot_panes: &[PlotPaneConfig]) -> HashSet<ColumnKeyDto> {
    plot_panes
        .iter()
        .flat_map(|pane| pane.columns.iter().cloned())
        .collect()
}

fn active_pane_ids(plot_panes: &[PlotPaneConfig]) -> HashSet<usize> {
    plot_panes.iter().map(|pane| pane.id).collect()
}

fn active_fpcs_pane_ids(plot_panes: &[PlotPaneConfig]) -> HashSet<usize> {
    plot_panes
        .iter()
        .filter(|pane| {
            pane.view.mode == PlotMode::Timeseries
                && pane.view.decimation_method == DecimationMethod::Fpcs
        })
        .map(|pane| pane.id)
        .collect()
}

fn pane_contains_column(pane: &PlotPaneConfig, key: &ColumnKeyDto) -> bool {
    pane.columns.contains(key)
        || pane.columns.iter().any(|active_key| {
            active_key.stream_id == key.stream_id && active_key.column_index == key.column_index
        })
}

fn update_default_pane_columns(
    plot_panes: &mut Vec<PlotPaneConfig>,
    columns: Vec<ColumnKeyDto>,
    view: &ViewConfig,
) {
    if plot_panes.is_empty() {
        *plot_panes = default_plot_panes(view);
    }

    if let Some(pane) = plot_panes.first_mut() {
        pane.columns = columns;
    }
}

fn apply_view_to_all_panes(plot_panes: &mut Vec<PlotPaneConfig>, view: &ViewConfig) {
    for pane in plot_panes {
        pane.view = view.clone();
    }
}

/// Upper bound on how many seconds of live samples we retain per stream. Needs
/// to scale with the user-selectable window (now up to 1000 s); the actual
/// per-stream memory is bounded in tandem by `MAX_RAW_POINTS_PER_STREAM` below.
const MAX_RETENTION_SECONDS: f64 = 1500.0;

/// Hard cap on raw points kept per stream. Prevents a long window combined
/// with a high sample rate from growing memory without bound: e.g. a 1000 s
/// window at 1 kHz would otherwise want 1M points/stream. Past this count
/// the oldest samples are dropped, so the visible window may be shorter
/// than requested for very high sample rates.
const MAX_RAW_POINTS_PER_STREAM: usize = 100_000;

fn live_retention_seconds(view: &ViewConfig) -> f64 {
    let window = view.window_seconds.max(1.0);
    (window * 1.5)
        .max(window + 5.0)
        .clamp(10.0, MAX_RETENTION_SECONDS)
}

/// Retention has to cover the longest derived window as well as the widest
/// pane: a 60 s noise-floor window over a 10 s pane would otherwise never see
/// a full window of source data and would never produce a point.
fn live_retention_seconds_for_panes(
    plot_panes: &[PlotPaneConfig],
    fallback: &ViewConfig,
    derived_channels: &[DerivedChannelDto],
) -> f64 {
    let pane_seconds = plot_panes
        .iter()
        .map(|pane| live_retention_seconds(&pane.view))
        .fold(live_retention_seconds(fallback), f64::max);

    derived_channels
        .iter()
        .map(|channel| derived_window_seconds(channel) * 1.5)
        .fold(pane_seconds, f64::max)
        .clamp(10.0, MAX_RETENTION_SECONDS)
}

fn retained_point_count(column_states: &HashMap<ColumnKeyDto, ColumnState>) -> usize {
    column_states.values().map(|state| state.raw.len()).sum()
}

fn data_range(column_states: &HashMap<ColumnKeyDto, ColumnState>) -> Option<(f64, f64)> {
    let mut start = f64::INFINITY;
    let mut end = f64::NEG_INFINITY;

    for point in column_states
        .values()
        .flat_map(|state| state.raw.iter())
        .filter(|point| point.x.is_finite())
    {
        start = start.min(point.x);
        end = end.max(point.x);
    }

    if start.is_finite() && end.is_finite() {
        Some((start, end))
    } else {
        None
    }
}

fn earliest_time(current: Option<f64>, candidate: Option<f64>) -> Option<f64> {
    match (current, candidate) {
        (Some(current), Some(candidate)) => Some(current.min(candidate)),
        (Some(current), None) => Some(current),
        (None, Some(candidate)) => Some(candidate),
        (None, None) => None,
    }
}

fn batch_time_reference_start(batch: &SampleBatch) -> Option<f64> {
    let segment = batch.segment();
    if segment.time_ref_session_id == 0 {
        return None;
    }

    match &segment.time_ref_epoch {
        MetadataEpoch::Unix | MetadataEpoch::Systime => {
            let start = batch.row(0)?.timestamp_begin();
            if start.is_finite() && start > 0.0 {
                Some(start)
            } else {
                None
            }
        }
        _ => None,
    }
}

fn fpcs_decimate_window(points: &[Point], sample_rate: f64, view: &ViewConfig) -> Vec<Point> {
    let target_points = target_plot_points(view);
    if points.len() <= target_points {
        return points.to_vec();
    }

    let ratio = fpcs_ratio(sample_rate, view);
    let mut fpcs = StreamingFpcs::new(ratio, target_points.max(2));
    for point in points {
        fpcs.process_point(*point);
    }
    fpcs.output.iter().copied().collect()
}

fn latest_active_x(
    column_states: &HashMap<ColumnKeyDto, ColumnState>,
    active_columns: &HashSet<ColumnKeyDto>,
) -> Option<f64> {
    active_columns
        .iter()
        .filter_map(|key| resolve_column_state(column_states, key).map(|(_, state)| state))
        .filter_map(|state| state.raw.back())
        .filter(|point| point.x.is_finite())
        .map(|point| point.x)
        .max_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal))
}

fn resolve_data_key(
    column_states: &HashMap<ColumnKeyDto, ColumnState>,
    key: &ColumnKeyDto,
) -> Option<ColumnKeyDto> {
    resolve_column_state(column_states, key).map(|(data_key, _)| data_key.clone())
}

fn resolve_column_state<'a>(
    column_states: &'a HashMap<ColumnKeyDto, ColumnState>,
    key: &ColumnKeyDto,
) -> Option<(&'a ColumnKeyDto, &'a ColumnState)> {
    let exact = column_states.get_key_value(key);
    if exact.is_some_and(|(_, state)| !state.raw.is_empty()) {
        return exact;
    }

    let mut candidates = column_states.iter().filter(|(candidate_key, state)| {
        candidate_key.stream_id == key.stream_id
            && candidate_key.column_index == key.column_index
            // A derived key shares its source's stream id and column index, so
            // without this the unify fallback would happily serve the source's
            // samples under the derived key.
            && candidate_key.derivation == key.derivation
            && !state.raw.is_empty()
    });
    let first = candidates.next();
    if first.is_some() && candidates.next().is_none() {
        return first;
    }

    exact
}

fn emit_active_columns(emitter: &Emitter, active_columns: &HashSet<ColumnKeyDto>) {
    let columns: Vec<_> = active_columns.iter().cloned().collect();
    emitter.emit(&json!({
        "type": "activeColumns",
        "columns": columns
    }));
}

fn emit_stream_values(
    emitter: &Emitter,
    column_states: &HashMap<ColumnKeyDto, ColumnState>,
) -> usize {
    let mut values: Vec<_> = column_states
        .iter()
        .filter_map(|(key, state)| {
            state
                .display_value
                .filter(|value| value.is_finite())
                .map(|value| StreamValueDto {
                    key: key.clone(),
                    value,
                })
        })
        .collect();
    values.sort_by(|a, b| {
        (&a.key.route, a.key.stream_id, a.key.column_index).cmp(&(
            &b.key.route,
            b.key.stream_id,
            b.key.column_index,
        ))
    });

    if values.is_empty() {
        return 0;
    }

    let value_count = values.len();
    emitter.emit(&json!({
        "type": "streamValues",
        "values": values
    }));
    value_count
}

fn emit_stream_values_for_view(
    emitter: &Emitter,
    column_states: &HashMap<ColumnKeyDto, ColumnState>,
    viewport_end: f64,
    window_seconds: f64,
) -> usize {
    if !viewport_end.is_finite() {
        return 0;
    }

    let window_seconds = window_seconds.max(1e-6);
    let viewport_start = viewport_end - window_seconds;
    let mut values: Vec<_> = column_states
        .iter()
        .filter_map(|(key, state)| {
            state
                .display_value_between(viewport_start, viewport_end)
                .filter(|value| value.is_finite())
                .map(|value| StreamValueDto {
                    key: key.clone(),
                    value,
                })
        })
        .collect();
    values.sort_by(|a, b| {
        (&a.key.route, a.key.stream_id, a.key.column_index).cmp(&(
            &b.key.route,
            b.key.stream_id,
            b.key.column_index,
        ))
    });

    if values.is_empty() {
        return 0;
    }

    let value_count = values.len();
    emitter.emit(&json!({
        "type": "streamValues",
        "values": values
    }));
    value_count
}

fn emit_live_plot(
    emitter: &Emitter,
    column_states: &HashMap<ColumnKeyDto, ColumnState>,
    active_columns: &HashSet<ColumnKeyDto>,
    plot_panes: &[PlotPaneConfig],
    fft_workers: &mut HashMap<usize, FftWorker>,
) -> Option<PlotEmitStats> {
    let pane_ids = active_pane_ids(plot_panes);
    fft_workers.retain(|pane_id, _| pane_ids.contains(pane_id));

    let shared_view_end = latest_active_x(column_states, active_columns);
    let mut aggregate: Option<PlotEmitStats> = None;

    for pane in plot_panes {
        let pane_columns = pane_columns_set(pane);
        let stats = match pane.view.mode {
            PlotMode::Timeseries => Some(emit_live_timeseries_plot(
                emitter,
                pane.id,
                column_states,
                &pane.columns,
                &pane.view,
                shared_view_end,
            )),
            PlotMode::Fft => {
                let fft_worker = fft_workers
                    .entry(pane.id)
                    .or_insert_with(|| FftWorker::new(emitter));
                emit_live_fft_plot(
                    emitter,
                    pane.id,
                    column_states,
                    &pane_columns,
                    &pane.view,
                    shared_view_end,
                    fft_worker,
                )
            }
        };

        if let Some(stats) = stats {
            aggregate = Some(match aggregate {
                Some(current) => PlotEmitStats {
                    mode: stats.mode,
                    series_count: current.series_count + stats.series_count,
                    point_count: current.point_count + stats.point_count,
                    viewport_end: stats.viewport_end.or(current.viewport_end),
                },
                None => stats,
            });
        }
    }

    aggregate
}

/// Build the timeseries series for one pane, anchoring the time window to the
/// pane's first column that has data. Columns whose time references roughly
/// agree fall inside the window and plot normally; columns on an incompatible
/// time base have no points in the window and are sent flagged (and empty) so
/// the legend can mark them.
fn build_live_timeseries_series<'a>(
    pane_id: usize,
    column_states: &'a HashMap<ColumnKeyDto, ColumnState>,
    pane_columns: &'a [ColumnKeyDto],
    view: &ViewConfig,
    shared_view_end: Option<f64>,
) -> (Option<f64>, Vec<BinaryPlotSeries<'a>>, usize) {
    // A derived column arrives at its own cadence — one point per second for a
    // noise floor — so anchoring the window to it would advance the right edge
    // in visible steps. Prefer a raw column; failing that, borrow the latest
    // timestamp from a derived column's source, which is on the same axis.
    let latest_x_of = |key: &ColumnKeyDto| {
        resolve_column_state(column_states, key)
            .and_then(|(_, state)| state.raw.back())
            .map(|point| point.x)
            .filter(|x| x.is_finite())
    };
    let view_end = pane_columns
        .iter()
        .filter(|key| !key.is_derived())
        .find_map(&latest_x_of)
        .or_else(|| {
            pane_columns
                .iter()
                .filter(|key| key.is_derived())
                .find_map(|key| latest_x_of(&key.source()))
        })
        .or(shared_view_end);

    let window_start = view_end
        .map(|end| end - view.window_seconds.max(1e-6))
        .unwrap_or(f64::NEG_INFINITY);
    let window_end = view_end.unwrap_or(f64::INFINITY);

    let mut series = Vec::new();
    let mut point_count = 0usize;

    for key in pane_columns {
        let Some((data_key, state)) = resolve_column_state(column_states, key) else {
            // A derived channel is addressable as soon as the user creates it,
            // before the engine has built any state for it. Report it rather
            // than dropping it, so the legend can show it warming up instead
            // of the trace simply not being there.
            if key.is_derived() {
                series.push(BinaryPlotSeries {
                    key,
                    sample_rate: 0.0,
                    points: PlotPointSource::Slice(&[]),
                    outside_window: false,
                    warming_up: true,
                    noise_floor: None,
                });
            }
            continue;
        };
        if state.raw.is_empty() {
            if key.is_derived() {
                series.push(BinaryPlotSeries {
                    key: data_key,
                    sample_rate: state.sample_rate,
                    points: PlotPointSource::Slice(&[]),
                    outside_window: false,
                    warming_up: true,
                    noise_floor: None,
                });
            }
            continue;
        }
        let points = match view.decimation_method {
            DecimationMethod::Fpcs => state
                .fpcs_for_pane(pane_id)
                .map(|fpcs| fpcs.point_source_since(window_start))
                .unwrap_or_else(|| state.point_source_between(window_start, window_end)),
            DecimationMethod::None => state.point_source_between(window_start, window_end),
        };

        // FPCS retains points since window_start regardless of the upper
        // bound, so verify the column actually overlaps the window before
        // declaring it visible.
        let overlaps_window = state
            .raw
            .back()
            .map(|latest| latest.x >= window_start)
            .unwrap_or(false)
            && state
                .raw
                .front()
                .map(|earliest| earliest.x <= window_end)
                .unwrap_or(false);

        if points.is_empty() || !overlaps_window {
            series.push(BinaryPlotSeries {
                key: data_key,
                sample_rate: state.sample_rate,
                points: PlotPointSource::Slice(&[]),
                outside_window: true,
                warming_up: false,
                noise_floor: None,
            });
            continue;
        }

        point_count += points.len();
        series.push(BinaryPlotSeries {
            key: data_key,
            sample_rate: state.sample_rate,
            points,
            outside_window: false,
            warming_up: false,
            noise_floor: None,
        });
    }

    (view_end, series, point_count)
}

fn emit_live_timeseries_plot(
    emitter: &Emitter,
    pane_id: usize,
    column_states: &HashMap<ColumnKeyDto, ColumnState>,
    pane_columns: &[ColumnKeyDto],
    view: &ViewConfig,
    shared_view_end: Option<f64>,
) -> PlotEmitStats {
    let (view_end, series, point_count) =
        build_live_timeseries_series(pane_id, column_states, pane_columns, view, shared_view_end);

    if let Err(err) = emitter.emit_plot_frame(pane_id, PlotMode::Timeseries, view_end, &series) {
        emitter.debug(format!("failed to emit binary timeseries plot: {err}"));
    }

    PlotEmitStats {
        mode: PlotMode::Timeseries,
        series_count: series.len(),
        point_count,
        viewport_end: view_end,
    }
}

fn emit_live_fft_plot(
    emitter: &Emitter,
    pane_id: usize,
    column_states: &HashMap<ColumnKeyDto, ColumnState>,
    active_columns: &HashSet<ColumnKeyDto>,
    view: &ViewConfig,
    view_end: Option<f64>,
    fft_worker: &mut FftWorker,
) -> Option<PlotEmitStats> {
    let window_seconds = view.window_seconds.max(1e-6);
    if fft_worker.is_ready_for_request() {
        let request = build_fft_request(
            fft_worker.generation,
            column_states,
            active_columns,
            view,
            view_end,
        );
        fft_worker.submit_request(request, emitter);
    }

    if let Some(result) = fft_worker.take_pending_emit(view_end, window_seconds) {
        let stats = PlotEmitStats {
            mode: PlotMode::Fft,
            series_count: result.series.len(),
            point_count: result.series.iter().map(|series| series.points.len()).sum(),
            viewport_end: result.viewport_end,
        };
        emit_plot_series_frame(
            emitter,
            pane_id,
            PlotMode::Fft,
            result.viewport_end,
            &result.series,
        );
        return Some(stats);
    }

    None
}

fn emit_plot_at(
    emitter: &Emitter,
    pane_id: usize,
    column_states: &HashMap<ColumnKeyDto, ColumnState>,
    active_columns: &HashSet<ColumnKeyDto>,
    view: &ViewConfig,
    viewport_end: Option<f64>,
) -> PlotEmitStats {
    let mut series = Vec::new();
    let is_live_latest_view = viewport_end.is_none();
    let view_end = viewport_end.or_else(|| latest_active_x(column_states, active_columns));
    let mut keys: Vec<_> = active_columns.iter().cloned().collect();
    keys.sort_by(|a, b| {
        (&a.route, a.stream_id, a.column_index).cmp(&(&b.route, b.stream_id, b.column_index))
    });

    for key in keys {
        let Some((_, state)) = resolve_column_state(column_states, &key) else {
            continue;
        };
        let label_state = column_states.get(&key).unwrap_or(state);
        let window_seconds = view.window_seconds.max(1e-6);
        let (points, noise_floor) = match view.mode {
            PlotMode::Timeseries => {
                let window_points = view_end.map(|end| {
                    let start = end - window_seconds;
                    state.points_between(start, end)
                });
                let points = match view.decimation_method {
                    DecimationMethod::Fpcs if is_live_latest_view => {
                        let start = state
                            .raw
                            .back()
                            .map(|point| point.x - view.window_seconds)
                            .unwrap_or(f64::NEG_INFINITY);
                        let points = state
                            .fpcs_for_pane(pane_id)
                            .map(|fpcs| fpcs.points_since(start))
                            .unwrap_or_default();
                        if points.is_empty() {
                            fpcs_decimate_window(
                                &state.recent_points(view.window_seconds),
                                state.sample_rate,
                                view,
                            )
                        } else {
                            points
                        }
                    }
                    DecimationMethod::Fpcs => window_points
                        .as_deref()
                        .map(|points| fpcs_decimate_window(points, state.sample_rate, view))
                        .unwrap_or_else(|| {
                            fpcs_decimate_window(
                                &state.recent_points(view.window_seconds),
                                state.sample_rate,
                                view,
                            )
                        }),
                    DecimationMethod::None => window_points
                        .clone()
                        .unwrap_or_else(|| state.recent_points(view.window_seconds)),
                };
                (points, None)
            }
            PlotMode::Fft => {
                let points = state.fft_window_points(window_seconds, view_end);
                let points = fft_points(&points, state.sample_rate, view.detrend);
                let noise_floor = estimate_white_noise_floor(&points);
                (points, noise_floor)
            }
        };

        if points.is_empty() {
            continue;
        }

        series.push(PlotSeries {
            key,
            label: label_state.label.clone(),
            units: label_state.units.clone(),
            sample_rate: state.sample_rate,
            points,
            noise_floor,
        });
    }

    let stats = PlotEmitStats {
        mode: view.mode,
        series_count: series.len(),
        point_count: series.iter().map(|series| series.points.len()).sum(),
        viewport_end: view_end,
    };

    emit_plot_series_frame(emitter, pane_id, view.mode, view_end, &series);
    stats
}

fn emit_plot_panes_at(
    emitter: &Emitter,
    column_states: &HashMap<ColumnKeyDto, ColumnState>,
    plot_panes: &[PlotPaneConfig],
    viewport_end: Option<f64>,
) -> Option<PlotEmitStats> {
    let mut aggregate: Option<PlotEmitStats> = None;

    for pane in plot_panes {
        let pane_columns = pane_columns_set(pane);
        let stats = emit_plot_at(
            emitter,
            pane.id,
            column_states,
            &pane_columns,
            &pane.view,
            viewport_end,
        );
        aggregate = Some(match aggregate {
            Some(current) => PlotEmitStats {
                mode: stats.mode,
                series_count: current.series_count + stats.series_count,
                point_count: current.point_count + stats.point_count,
                viewport_end: stats.viewport_end.or(current.viewport_end),
            },
            None => stats,
        });
    }

    aggregate
}

fn emit_plot_series_frame(
    emitter: &Emitter,
    pane_id: usize,
    mode: PlotMode,
    viewport_end: Option<f64>,
    series: &[PlotSeries],
) {
    let binary_series: Vec<_> = series
        .iter()
        .map(|item| BinaryPlotSeries {
            key: &item.key,
            sample_rate: item.sample_rate,
            points: PlotPointSource::Slice(&item.points),
            outside_window: false,
            warming_up: false,
            noise_floor: item.noise_floor,
        })
        .collect();
    if let Err(err) = emitter.emit_plot_frame(pane_id, mode, viewport_end, &binary_series) {
        emitter.debug(format!("failed to emit binary plot: {err}"));
    }
}

fn build_fft_request(
    generation: u64,
    column_states: &HashMap<ColumnKeyDto, ColumnState>,
    active_columns: &HashSet<ColumnKeyDto>,
    view: &ViewConfig,
    viewport_end: Option<f64>,
) -> FftRequest {
    let mut inputs = Vec::new();
    let window_seconds = view.window_seconds.max(1e-6);
    let mut keys: Vec<_> = active_columns.iter().cloned().collect();
    keys.sort_by(|a, b| {
        (&a.route, a.stream_id, a.column_index).cmp(&(&b.route, b.stream_id, b.column_index))
    });

    for key in keys {
        let Some((_, state)) = resolve_column_state(column_states, &key) else {
            continue;
        };
        let label_state = column_states.get(&key).unwrap_or(state);
        let points = state.fft_window_points(window_seconds, viewport_end);
        if points.len() < 16 || state.sample_rate <= 0.0 {
            continue;
        }
        inputs.push(FftSeriesInput {
            key,
            label: label_state.label.clone(),
            units: label_state.units.clone(),
            sample_rate: state.sample_rate,
            points,
        });
    }

    FftRequest {
        generation,
        viewport_end,
        window_seconds,
        detrend: view.detrend,
        target_points: target_plot_points(view),
        inputs,
    }
}

fn build_view_data_tsv(
    column_states: &HashMap<ColumnKeyDto, ColumnState>,
    active_columns: &HashSet<ColumnKeyDto>,
    view: &ViewConfig,
    viewport_end: Option<f64>,
) -> String {
    let view_end = viewport_end.or_else(|| latest_active_x(column_states, active_columns));
    let mut keys: Vec<_> = active_columns.iter().cloned().collect();
    keys.sort_by(|a, b| {
        (&a.route, a.stream_id, a.column_index).cmp(&(&b.route, b.stream_id, b.column_index))
    });

    let mut series = Vec::new();
    let window_seconds = view.window_seconds.max(1e-6);
    for key in keys {
        let Some((_, state)) = resolve_column_state(column_states, &key) else {
            continue;
        };
        let label_state = column_states.get(&key).unwrap_or(state);
        let points = match view.mode {
            PlotMode::Timeseries => {
                if let Some(end) = view_end {
                    let start = end - window_seconds;
                    state.points_between(start, end)
                } else {
                    state.recent_points(window_seconds)
                }
            }
            PlotMode::Fft => {
                let raw_points = state.fft_window_points(window_seconds, view_end);
                fft_points(&raw_points, state.sample_rate, view.detrend)
            }
        };

        series.push(ViewDataSeries {
            label: label_state.label.clone(),
            points,
        });
    }

    build_wide_view_data_tsv(
        match view.mode {
            PlotMode::Timeseries => "time",
            PlotMode::Fft => "frequency",
        },
        series,
    )
}

fn build_wide_view_data_tsv(x_header: &str, mut series: Vec<ViewDataSeries>) -> String {
    let mut output = String::new();
    output.push_str(x_header);
    for item in &series {
        output.push('\t');
        output.push_str(&escape_tsv(&item.label));
    }
    output.push('\n');

    let mut xs = Vec::new();
    let mut seen_xs = HashSet::new();
    for item in &mut series {
        item.points
            .retain(|point| point.x.is_finite() && point.y.is_finite());
        item.points
            .sort_by(|a, b| a.x.partial_cmp(&b.x).unwrap_or(std::cmp::Ordering::Equal));
        for point in &item.points {
            if seen_xs.insert(view_data_x_key(point.x)) {
                xs.push(point.x);
            }
        }
    }
    xs.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));

    let value_maps: Vec<HashMap<u64, f64>> = series
        .iter()
        .map(|item| {
            item.points
                .iter()
                .map(|point| (view_data_x_key(point.x), point.y))
                .collect()
        })
        .collect();

    for x in xs {
        output.push_str(&format!("{x:.17}"));
        let x_key = view_data_x_key(x);
        for values in &value_maps {
            output.push('\t');
            if let Some(y) = values.get(&x_key) {
                output.push_str(&format!("{y:.17}"));
            }
        }
        output.push('\n');
    }
    output
}

fn view_data_x_key(x: f64) -> u64 {
    if x == 0.0 {
        0.0_f64.to_bits()
    } else {
        x.to_bits()
    }
}

fn emit_view_data(emitter: &Emitter, request_id: String, result: Result<String, String>) {
    match result {
        Ok(text) => {
            let rows = text.lines().count().saturating_sub(1);
            emitter.emit(&json!({
                "type": "viewData",
                "requestId": request_id,
                "ok": true,
                "text": text,
                "rows": rows
            }));
        }
        Err(error) => emitter.emit(&json!({
            "type": "viewData",
            "requestId": request_id,
            "ok": false,
            "error": error
        })),
    }
}

fn emit_export_result(
    emitter: &Emitter,
    request_id: String,
    output_path: String,
    format: ExportFormat,
    result: Result<ExportSummary, String>,
) {
    match result {
        Ok(summary) => emitter.emit(&json!({
            "type": "exportResult",
            "requestId": request_id,
            "ok": true,
            "outputPath": output_path,
            "format": format,
            "rows": summary.rows,
            "bytes": summary.bytes
        })),
        Err(error) => emitter.emit(&json!({
            "type": "exportResult",
            "requestId": request_id,
            "ok": false,
            "outputPath": output_path,
            "format": format,
            "error": error
        })),
    }
}

fn escape_tsv(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('\t', "\\t")
        .replace('\n', "\\n")
        .replace('\r', "\\r")
}

fn calculate_fft_request(request: FftRequest) -> FftResult {
    let series = request
        .inputs
        .into_iter()
        .filter_map(|input| {
            let points = fft_points(&input.points, input.sample_rate, request.detrend);
            let noise_floor = estimate_white_noise_floor(&points);
            let points = decimate_min_max_by_x(&points, request.target_points);
            if points.is_empty() {
                return None;
            }
            Some(PlotSeries {
                key: input.key,
                label: input.label,
                units: input.units,
                sample_rate: input.sample_rate,
                points,
                noise_floor,
            })
        })
        .collect();

    FftResult {
        generation: request.generation,
        viewport_end: request.viewport_end,
        window_seconds: request.window_seconds,
        series,
    }
}

fn decimate_min_max_by_x(points: &[Point], target_points: usize) -> Vec<Point> {
    if points.len() <= target_points || target_points < 4 {
        return points.to_vec();
    }

    let bucket_count = (target_points / 2).max(1);
    let bucket_size = (points.len() as f64 / bucket_count as f64).ceil() as usize;
    let mut output = Vec::with_capacity(target_points);

    for bucket in points.chunks(bucket_size.max(1)) {
        let Some((min_index, min_point)) = bucket
            .iter()
            .enumerate()
            .min_by(|(_, a), (_, b)| a.y.partial_cmp(&b.y).unwrap_or(std::cmp::Ordering::Equal))
        else {
            continue;
        };
        let Some((max_index, max_point)) = bucket
            .iter()
            .enumerate()
            .max_by(|(_, a), (_, b)| a.y.partial_cmp(&b.y).unwrap_or(std::cmp::Ordering::Equal))
        else {
            continue;
        };

        if min_index == max_index {
            output.push(*min_point);
        } else if min_point.x <= max_point.x {
            output.push(*min_point);
            output.push(*max_point);
        } else {
            output.push(*max_point);
            output.push(*min_point);
        }
    }

    output
}

fn fft_points(points: &[Point], sample_rate: f64, detrend: DetrendMethod) -> Vec<Point> {
    if points.len() < 16 || sample_rate <= 0.0 {
        return Vec::new();
    }

    let y: Vec<f64> = points.iter().map(|point| point.y).collect();
    let y = detrended_values(&y, detrend);
    let timestamps: Vec<f64> = points.iter().map(|point| point.x).collect();

    // Detrending stays app-side (`WelchOp` has none); the Welch estimate
    // itself is the library's, shared with `tio monitor`.
    let mut op = WelchOp::new(y.len(), sample_rate, 0.0);
    op.update_batch(&timestamps, &ColumnArray::F64(y.into()));
    match op.output() {
        Ok(data) => data.points.iter().map(|&(x, y)| Point { x, y }).collect(),
        Err(_) => Vec::new(),
    }
}

/// Estimate the flat, broadband ASD level while rejecting low-frequency 1/f
/// content and narrow spectral peaks. The estimator originated here and moved
/// upstream into twinleaf-tools; this adapts it to the plot `Point` type.
fn estimate_white_noise_floor(points: &[Point]) -> Option<f64> {
    let pairs: Vec<(f64, f64)> = points.iter().map(|point| (point.x, point.y)).collect();
    twinleaf_tools::tui::spectral::estimate_white_noise_floor(&pairs)
}

fn detrended_values(y: &[f64], detrend: DetrendMethod) -> Vec<f64> {
    match detrend {
        DetrendMethod::None => y.to_vec(),
        DetrendMethod::Mean => remove_mean(y),
        DetrendMethod::Linear => remove_linear_trend(y),
        DetrendMethod::Quadratic => remove_quadratic_trend(y),
    }
}

fn remove_mean(y: &[f64]) -> Vec<f64> {
    if y.is_empty() {
        return Vec::new();
    }
    let mean = y.iter().sum::<f64>() / y.len() as f64;
    y.iter().map(|value| value - mean).collect()
}

fn remove_linear_trend(y: &[f64]) -> Vec<f64> {
    if y.len() < 2 {
        return remove_mean(y);
    }

    let center = (y.len() as f64 - 1.0) * 0.5;
    let mut sum_x = 0.0;
    let mut sum_y = 0.0;
    let mut sum_x2 = 0.0;
    let mut sum_xy = 0.0;

    for (index, value) in y.iter().enumerate() {
        let x = index as f64 - center;
        sum_x += x;
        sum_y += value;
        sum_x2 += x * x;
        sum_xy += x * value;
    }

    let n = y.len() as f64;
    let denom = n * sum_x2 - sum_x * sum_x;
    if denom.abs() < 1e-12 {
        return remove_mean(y);
    }

    let slope = (n * sum_xy - sum_x * sum_y) / denom;
    let intercept = (sum_y - slope * sum_x) / n;

    y.iter()
        .enumerate()
        .map(|(index, value)| {
            let x = index as f64 - center;
            value - (intercept + slope * x)
        })
        .collect()
}

fn remove_quadratic_trend(y: &[f64]) -> Vec<f64> {
    if y.len() < 3 {
        return remove_linear_trend(y);
    }

    let center = (y.len() as f64 - 1.0) * 0.5;
    let mut s0 = 0.0;
    let mut s1 = 0.0;
    let mut s2 = 0.0;
    let mut s3 = 0.0;
    let mut s4 = 0.0;
    let mut sy = 0.0;
    let mut sxy = 0.0;
    let mut sx2y = 0.0;

    for (index, value) in y.iter().enumerate() {
        let x = index as f64 - center;
        let x2 = x * x;
        s0 += 1.0;
        s1 += x;
        s2 += x2;
        s3 += x2 * x;
        s4 += x2 * x2;
        sy += value;
        sxy += x * value;
        sx2y += x2 * value;
    }

    let Some([c0, c1, c2]) = solve_3x3([[s0, s1, s2, sy], [s1, s2, s3, sxy], [s2, s3, s4, sx2y]])
    else {
        return remove_linear_trend(y);
    };

    y.iter()
        .enumerate()
        .map(|(index, value)| {
            let x = index as f64 - center;
            value - (c0 + c1 * x + c2 * x * x)
        })
        .collect()
}

fn solve_3x3(mut matrix: [[f64; 4]; 3]) -> Option<[f64; 3]> {
    for col in 0..3 {
        let mut pivot = col;
        for row in (col + 1)..3 {
            if matrix[row][col].abs() > matrix[pivot][col].abs() {
                pivot = row;
            }
        }

        if matrix[pivot][col].abs() < 1e-12 {
            return None;
        }

        if pivot != col {
            matrix.swap(pivot, col);
        }

        let divisor = matrix[col][col];
        for item in &mut matrix[col][col..4] {
            *item /= divisor;
        }

        for row in 0..3 {
            if row == col {
                continue;
            }
            let factor = matrix[row][col];
            for item in col..4 {
                matrix[row][item] -= factor * matrix[col][item];
            }
        }
    }

    Some([matrix[0][3], matrix[1][3], matrix[2][3]])
}

fn dispatch_rpc(
    proxy: &Arc<proxy::Interface>,
    rpc_index: &HashMap<(String, String), RpcDto>,
    request_id: String,
    route: String,
    name: String,
    arg: Option<Value>,
    emitter: &Emitter,
) {
    let Some(rpc_meta) = rpc_index.get(&(route.clone(), name.clone())).cloned() else {
        emitter.emit(&json!({
            "type": "rpcResult",
            "requestId": request_id,
            "ok": false,
            "error": "RPC not found"
        }));
        return;
    };

    if rpc_base_type(&rpc_meta.arg_type) == "capture" {
        let request_id_for_error = request_id.clone();
        let proxy = Arc::clone(proxy);
        let worker_emitter = emitter.clone();
        let error_emitter = emitter.clone();
        if let Err(err) = thread::Builder::new()
            .name("twinleaf-capture-rpc".into())
            .spawn(move || {
                execute_rpc(
                    &proxy,
                    rpc_meta,
                    request_id,
                    route,
                    name,
                    arg,
                    &worker_emitter,
                )
            })
        {
            error_emitter.emit(&json!({
                "type": "rpcResult",
                "requestId": request_id_for_error,
                "ok": false,
                "error": format!("Failed to start capture worker: {err}")
            }));
        }
        return;
    }

    execute_rpc(proxy, rpc_meta, request_id, route, name, arg, emitter);
}

fn execute_rpc(
    proxy: &Arc<proxy::Interface>,
    rpc_meta: RpcDto,
    request_id: String,
    route: String,
    name: String,
    arg: Option<Value>,
    emitter: &Emitter,
) {
    let route_value = match DeviceRoute::from_str(&route) {
        Ok(route) => route,
        Err(_) => {
            emitter.emit(&json!({
                "type": "rpcResult",
                "requestId": request_id,
                "ok": false,
                "error": "Invalid route"
            }));
            return;
        }
    };

    let port = match proxy.device_rpc(route_value) {
        Ok(port) => port,
        Err(err) => {
            emitter.emit(&json!({
                "type": "rpcResult",
                "requestId": request_id,
                "ok": false,
                "error": format!("{err:?}")
            }));
            return;
        }
    };

    if rpc_base_type(&rpc_meta.arg_type) == "capture" {
        execute_capture_rpc(port, request_id, route, name, emitter);
        return;
    }

    let arg_bytes = match json_to_bytes(arg, &rpc_meta.arg_type) {
        Ok(bytes) => bytes,
        Err(err) => {
            emitter.emit(&json!({
                "type": "rpcResult",
                "requestId": request_id,
                "ok": false,
                "error": err
            }));
            return;
        }
    };

    match panic::catch_unwind(AssertUnwindSafe(|| port.raw_rpc(&name, &arg_bytes))) {
        Ok(Ok(reply)) => emitter.emit(&json!({
            "type": "rpcResult",
            "requestId": request_id,
            "ok": true,
            "route": route,
            "name": name,
            "value": bytes_to_json_value(&reply, &rpc_meta.arg_type)
        })),
        Ok(Err(err)) => emitter.emit(&json!({
            "type": "rpcResult",
            "requestId": request_id,
            "ok": false,
            "route": route,
            "name": name,
            "error": format!("{err:?}")
        })),
        Err(err) => emitter.emit(&json!({
            "type": "rpcResult",
            "requestId": request_id,
            "ok": false,
            "route": route,
            "name": name,
            "error": format!("Twinleaf parser panic while calling RPC: {}", panic_message(err))
        })),
    }
}

fn execute_capture_rpc(
    port: proxy::Port,
    request_id: String,
    route: String,
    name: String,
    emitter: &Emitter,
) {
    const CAPTURE_TIMEOUT: Duration = Duration::from_secs(2);
    match panic::catch_unwind(AssertUnwindSafe(|| {
        let capture_rpc = PortCaptureRpc { port: &port };
        read_capture(&capture_rpc, &name, CAPTURE_TIMEOUT)
    })) {
        Ok(Ok(readout)) => emitter.emit(&json!({
            "type": "rpcResult",
            "requestId": request_id,
            "ok": true,
            "route": route,
            "name": name,
            "value": capture_readout_to_json_value(&readout)
        })),
        Ok(Err(err)) => emitter.emit(&json!({
            "type": "rpcResult",
            "requestId": request_id,
            "ok": false,
            "route": route,
            "name": name,
            "error": format!("{err}")
        })),
        Err(err) => emitter.emit(&json!({
            "type": "rpcResult",
            "requestId": request_id,
            "ok": false,
            "route": route,
            "name": name,
            "error": format!("Twinleaf parser panic while calling RPC: {}", panic_message(err))
        })),
    }
}

struct PortCaptureRpc<'a> {
    port: &'a proxy::Port,
}

impl CaptureRpc for PortCaptureRpc<'_> {
    fn capture_raw_rpc(&self, name: &str, arg: &[u8]) -> Result<Vec<u8>, proxy::RpcError> {
        self.port.raw_rpc(name, arg)
    }
}

fn capture_readout_to_json_value(readout: &CaptureReadout) -> Value {
    use std::fmt::Write as _;

    let metadata = &readout.metadata;
    let mut text = String::new();
    let mut points = Vec::new();
    let _ = writeln!(text, "# capture {}", metadata.name);
    let _ = writeln!(text, "# y {} ({})", metadata.name, metadata.units);
    let _ = writeln!(text, "# x {} ({})", metadata.x_name, metadata.x_units);
    let _ = writeln!(
        text,
        "# data_type={} length={} size={} blocksize={} y_calibration={}",
        metadata.data_type_label(),
        metadata.length,
        metadata.size,
        metadata.blocksize,
        metadata.y_calibration
    );

    match readout.values_f64() {
        Ok(values) => {
            for (index, y) in values.into_iter().enumerate() {
                let x = metadata.x_value_f64(index);
                points.push(json!([x, y]));
                let _ = writeln!(text, "{}\t{}", x, y);
            }
        }
        Err(err) => {
            let _ = writeln!(text, "# failed to decode capture values: {err}");
        }
    }

    json!({
        "encoding": "capture",
        "bytes": readout.data.len(),
        "text": text,
        "points": points,
        "metadata": {
            "name": &metadata.name,
            "units": &metadata.units,
            "xName": &metadata.x_name,
            "xUnits": &metadata.x_units,
            "dataType": metadata.data_type_label(),
            "length": metadata.length,
            "size": metadata.size,
            "blocksize": metadata.blocksize,
            "yCalibration": metadata.y_calibration,
            "xOffset": metadata.x_offset,
            "xStride": metadata.x_stride
        }
    })
}

fn rpc_base_type(rpc_type: &str) -> &str {
    rpc_type.split('<').next().unwrap_or(rpc_type)
}

fn rpc_arg_type(descriptor: &RpcDescriptor) -> String {
    if descriptor.meta.is_unknown() {
        return if is_capture_rpc_descriptor(descriptor) {
            "capture".to_string()
        } else {
            "missing".to_string()
        };
    }

    if is_capture_rpc_descriptor(descriptor) {
        return "capture".to_string();
    }

    if descriptor.meta.flags().contains(RpcMetaFlags::BOOL) {
        return descriptor.meta.type_str();
    }

    match descriptor.meta.kind() {
        RpcValueType::Unit => "unit".to_string(),
        RpcValueType::Raw { .. } => "missing".to_string(),
        _ => descriptor.meta.type_str(),
    }
}

fn rpc_size(descriptor: &RpcDescriptor) -> usize {
    if is_capture_rpc_descriptor(descriptor) {
        return 0;
    }

    match descriptor.meta.kind() {
        RpcValueType::String { max_len } => max_len.map(|len| usize::from(len.get())).unwrap_or(0),
        _ => descriptor.meta.size_bytes().unwrap_or(0),
    }
}

fn rpc_permissions(descriptor: &RpcDescriptor) -> String {
    if descriptor.meta.is_unknown() && is_capture_rpc_descriptor(descriptor) {
        "R--".to_string()
    } else {
        descriptor.meta.perm_str()
    }
}

fn rpc_readable(descriptor: &RpcDescriptor) -> bool {
    descriptor.meta.flags().contains(RpcMetaFlags::READABLE)
        || is_capture_rpc_descriptor(descriptor)
}

fn rpc_unknown(descriptor: &RpcDescriptor) -> bool {
    descriptor.meta.is_unknown() && !is_capture_rpc_descriptor(descriptor)
}

fn is_capture_rpc_descriptor(descriptor: &RpcDescriptor) -> bool {
    descriptor.meta.flags().contains(RpcMetaFlags::CAPTURE)
        || is_capture_rpc_name(&descriptor.full_name)
}

fn is_capture_rpc_name(name: &str) -> bool {
    name.rsplit('.').next() == Some("capture")
}

/// Map the Swift-facing base-type vocabulary onto the library's value types.
/// `bool` travels as a one-byte unsigned integer on the wire.
fn rpc_value_type_for(base_type: &str) -> Option<RpcValueType> {
    let value_type = match base_type {
        "bool" | "u8" => RpcValueType::Int {
            signed: false,
            size: 1,
        },
        "u16" => RpcValueType::Int {
            signed: false,
            size: 2,
        },
        "u32" => RpcValueType::Int {
            signed: false,
            size: 4,
        },
        "u64" => RpcValueType::Int {
            signed: false,
            size: 8,
        },
        "i8" => RpcValueType::Int {
            signed: true,
            size: 1,
        },
        "i16" => RpcValueType::Int {
            signed: true,
            size: 2,
        },
        "i32" => RpcValueType::Int {
            signed: true,
            size: 4,
        },
        "i64" => RpcValueType::Int {
            signed: true,
            size: 8,
        },
        "f32" => RpcValueType::Float { size: 4 },
        "f64" => RpcValueType::Float { size: 8 },
        "string" => RpcValueType::String { max_len: None },
        _ => return None,
    };
    Some(value_type)
}

fn bytes_to_json_value(reply_bytes: &[u8], rpc_type: &str) -> Option<Value> {
    let base_type = rpc_base_type(rpc_type);
    if reply_bytes.is_empty() {
        return match base_type {
            "string" => Some(json!("")),
            _ => Some(Value::Null),
        };
    }
    if matches!(base_type, "unit" | "" | "missing") {
        return Some(Value::Null);
    }

    let value = rpc_value_type_for(base_type)?.decode(reply_bytes).ok()?;
    match (base_type, value) {
        ("bool", RpcValue::U64(value)) => Some(json!(value != 0)),
        // Serialize at the wire width so a float reads back as the short
        // decimal the device stores, not its f64-widened expansion.
        ("f32", RpcValue::F64(value)) => Some(json!(value as f32)),
        (_, RpcValue::U64(value)) => Some(json!(value)),
        (_, RpcValue::I64(value)) => Some(json!(value)),
        (_, RpcValue::F64(value)) => Some(json!(value)),
        // Device strings are NUL-padded; report only the leading run.
        ("string", RpcValue::Str(value)) => {
            Some(json!(value.split('\0').next().unwrap_or("").to_string()))
        }
        ("string", RpcValue::Bytes(bytes)) => {
            let string_bytes = bytes.split(|byte| *byte == 0).next().unwrap_or(&bytes);
            Some(json!(String::from_utf8_lossy(string_bytes).to_string()))
        }
        _ => None,
    }
}

fn json_to_bytes(arg: Option<Value>, rpc_type: &str) -> Result<Vec<u8>, String> {
    let Some(arg) = arg else {
        return Ok(Vec::new());
    };

    let base_type = rpc_base_type(rpc_type);
    if matches!(base_type, "unit" | "" | "missing") {
        return Ok(Vec::new());
    }
    let value_type = rpc_value_type_for(base_type)
        .ok_or_else(|| format!("Unsupported RPC argument type: {base_type}"))?;
    let value = match base_type {
        "bool" => RpcValue::U64(u64::from(
            arg.as_bool().ok_or_else(|| "Expected a bool".to_string())?,
        )),
        "string" => RpcValue::Str(
            arg.as_str()
                .ok_or_else(|| "Expected a string".to_string())?
                .to_string(),
        ),
        "u8" | "u16" | "u32" | "u64" => RpcValue::U64(
            arg.as_u64()
                .ok_or_else(|| format!("Expected a {base_type}"))?,
        ),
        "i8" | "i16" | "i32" | "i64" => RpcValue::I64(
            arg.as_i64()
                .ok_or_else(|| format!("Expected an {base_type}"))?,
        ),
        "f32" | "f64" => RpcValue::F64(
            arg.as_f64()
                .ok_or_else(|| format!("Expected an {base_type}"))?,
        ),
        other => return Err(format!("Unsupported RPC argument type: {other}")),
    };
    value_type.encode(&value).map_err(|err| err.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_camel_case_rpc_command_fields() {
        let command: ClientCommand = serde_json::from_value(json!({
            "type": "callRpc",
            "requestId": "req-1",
            "route": "/",
            "name": "device.name",
            "arg": null
        }))
        .unwrap();

        match command {
            ClientCommand::CallRpc {
                request_id,
                route,
                name,
                arg,
            } => {
                assert_eq!(request_id, "req-1");
                assert_eq!(route, "/");
                assert_eq!(name, "device.name");
                assert_eq!(arg, None);
            }
            other => panic!("unexpected command: {other:?}"),
        }
    }

    #[test]
    fn decodes_other_camel_case_command_fields() {
        let command: ClientCommand = serde_json::from_value(json!({
            "type": "copyViewData",
            "requestId": "copy-1",
            "viewportEnd": 12.5
        }))
        .unwrap();

        match command {
            ClientCommand::CopyViewData {
                request_id,
                pane_id,
                viewport_end,
            } => {
                assert_eq!(request_id, "copy-1");
                assert_eq!(pane_id, None);
                assert_eq!(viewport_end, Some(12.5));
            }
            other => panic!("unexpected command: {other:?}"),
        }

        let command: ClientCommand = serde_json::from_value(json!({
            "type": "exportLog",
            "requestId": "export-1",
            "sourcePath": "/tmp/source.tio",
            "outputPath": "/tmp/output.csv",
            "format": "csv"
        }))
        .unwrap();

        match command {
            ClientCommand::ExportLog {
                request_id,
                source_path,
                output_path,
                format,
            } => {
                assert_eq!(request_id, "export-1");
                assert_eq!(source_path, "/tmp/source.tio");
                assert_eq!(output_path, "/tmp/output.csv");
                assert_eq!(format, ExportFormat::Csv);
            }
            other => panic!("unexpected command: {other:?}"),
        }
    }

    #[test]
    fn maps_rpc_descriptors_to_bridge_metadata() {
        let missing = RpcDescriptor::from_meta(0, "missing.rpc".to_string());
        assert_eq!(rpc_arg_type(&missing), "missing");
        assert_eq!(rpc_size(&missing), 0);
        assert_eq!(missing.meta.perm_str(), "???");
        assert!(missing.meta.is_unknown());

        let unsupported = RpcDescriptor::from_meta(
            RpcMetaFlags::READABLE.bits() | (1 << 4) | 2,
            "bad.float".to_string(),
        );
        assert_eq!(rpc_arg_type(&unsupported), "missing");
        assert_eq!(rpc_size(&unsupported), 0);
        assert_eq!(unsupported.meta.perm_str(), "R--");

        let enabled = RpcDescriptor::from_meta(
            RpcMetaFlags::READABLE.bits()
                | RpcMetaFlags::WRITABLE.bits()
                | (1 << 4)
                | RpcMetaFlags::BOOL.bits(),
            "test.enable".to_string(),
        );
        assert_eq!(rpc_arg_type(&enabled), "bool");
        assert_eq!(rpc_size(&enabled), 1);
        assert_eq!(enabled.meta.perm_str(), "RW-");
        assert!(enabled.meta.flags().contains(RpcMetaFlags::READABLE));
        assert!(enabled.meta.flags().contains(RpcMetaFlags::WRITABLE));

        let action = RpcDescriptor::from_meta(RpcMetaFlags::WRITABLE.bits(), "test.go".to_string());
        assert_eq!(rpc_arg_type(&action), "unit");
        assert_eq!(rpc_size(&action), 0);
        assert_eq!(action.meta.perm_str(), "-W-");

        let capture = RpcDescriptor::from_meta(
            RpcMetaFlags::READABLE.bits() | RpcMetaFlags::CAPTURE.bits(),
            "test.capture".to_string(),
        );
        assert_eq!(rpc_arg_type(&capture), "capture");
        assert_eq!(rpc_size(&capture), 0);
        assert_eq!(rpc_permissions(&capture), "R--");
        assert!(rpc_readable(&capture));
        assert!(!rpc_unknown(&capture));

        let legacy_capture = RpcDescriptor::from_meta(0, "test.capture".to_string());
        assert_eq!(rpc_arg_type(&legacy_capture), "capture");
        assert_eq!(rpc_size(&legacy_capture), 0);
        assert_eq!(rpc_permissions(&legacy_capture), "R--");
        assert!(rpc_readable(&legacy_capture));
        assert!(!rpc_unknown(&legacy_capture));

        let string = RpcDescriptor::from_meta(
            RpcMetaFlags::READABLE.bits() | (8 << 4) | 3,
            "device.name".to_string(),
        );
        assert_eq!(rpc_arg_type(&string), "string<8>");
        assert_eq!(rpc_size(&string), 8);
        assert_eq!(string.meta.perm_str(), "R--");
    }

    #[test]
    fn flags_series_outside_the_anchored_time_window() {
        let key_a = ColumnKeyDto::raw("/0".to_string(), 1, 0);
        let key_b = ColumnKeyDto::raw("/1".to_string(), 1, 0);

        // Stream A's clock is near x=1000; stream B's is near x=20: their
        // time references are not compatible within the 10 s default window.
        let mut state_a = ColumnState::new("a".to_string(), "V".to_string(), 1.0);
        let mut state_b = ColumnState::new("b".to_string(), "V".to_string(), 1.0);
        for i in 0..20 {
            state_a.push_raw(
                Point {
                    x: 1000.0 + i as f64,
                    y: 1.0,
                },
                1e9,
            );
            state_b.push_raw(
                Point {
                    x: 5.0 + i as f64,
                    y: 2.0,
                },
                1e9,
            );
        }
        let states = HashMap::from([(key_a.clone(), state_a), (key_b.clone(), state_b)]);
        let view = ViewConfig::default();

        // Anchored to the first pane column (stream A).
        let pane = vec![key_a.clone(), key_b.clone()];
        let (view_end, series, _) = build_live_timeseries_series(0, &states, &pane, &view, None);
        assert_eq!(view_end, Some(1019.0));
        assert_eq!(series.len(), 2);
        assert!(!series[0].outside_window);
        assert!(series[0].points.len() > 0);
        assert!(series[1].outside_window);
        assert_eq!(series[1].points.len(), 0);

        // Swapping the pane order anchors to stream B instead.
        let pane = vec![key_b.clone(), key_a.clone()];
        let (view_end, series, _) = build_live_timeseries_series(0, &states, &pane, &view, None);
        assert_eq!(view_end, Some(24.0));
        assert!(!series[0].outside_window);
        assert!(series[0].points.len() > 0);
        assert!(series[1].outside_window);
        assert_eq!(series[1].points.len(), 0);
    }

    #[test]
    fn noise_floor_estimate_tracks_the_spectrum_it_is_taken_from() {
        // Deterministic white noise of a known level, with a strong tone on
        // top so peak rejection is exercised.
        let sample_rate: f64 = 1000.0;
        let target_asd = 0.02_f64;
        let sigma = target_asd * (sample_rate / 2.0).sqrt();
        let mut gauss = gaussian_noise(0x2545F4914F6CDD1D);

        let points: Vec<Point> = (0..20_000)
            .map(|index| {
                let t = index as f64 / sample_rate;
                Point {
                    x: t,
                    y: (std::f64::consts::TAU * 60.0 * t).sin() + sigma * gauss(),
                }
            })
            .collect();

        let spectrum = fft_points(&points, sample_rate, DetrendMethod::Quadratic);
        let estimate = estimate_white_noise_floor(&spectrum).expect("estimate");

        // The estimator's job is to recover the broadband level of the
        // spectrum it was handed, rejecting the tone. Measured against that
        // spectrum's own bins it is accurate to well under a percent.
        let mut broadband: Vec<f64> = spectrum
            .iter()
            .filter(|point| point.x > 100.0 && point.x < 400.0 && point.y.is_finite())
            .map(|point| point.y)
            .collect();
        broadband.sort_by(f64::total_cmp);
        let median_bin = broadband[broadband.len() / 2];
        let accuracy = estimate / median_bin;
        assert!(
            (0.97..1.03).contains(&accuracy),
            "estimator drifted from its own spectrum: {accuracy}"
        );

        // And against the injected level it is accurate to a couple of
        // percent. The small remaining shortfall is inherent to a median-based
        // estimator over chi-squared distributed bins, not a scale error.
        let against_truth = estimate / target_asd;
        assert!(
            (0.95..1.05).contains(&against_truth),
            "noise floor no longer matches the injected level: {against_truth}"
        );
    }

    #[test]
    fn spectrum_places_a_tone_at_its_true_frequency() {
        // A tone near the top of the band is where a stretched frequency axis
        // shows up worst, since the error grows with frequency. The tolerance
        // here is half a bin, well under the ~0.05% full-scale stretch the
        // crate's own `frequency()` introduces.
        let sample_rate: f64 = 1000.0;
        let tone_hz = 400.0;
        let points: Vec<Point> = (0..16_384)
            .map(|index| {
                let t = index as f64 / sample_rate;
                Point {
                    x: t,
                    y: (std::f64::consts::TAU * tone_hz * t).sin(),
                }
            })
            .collect();

        let spectrum = fft_points(&points, sample_rate, DetrendMethod::Mean);
        let peak = spectrum
            .iter()
            .max_by(|a, b| a.y.total_cmp(&b.y))
            .expect("peak");
        let spacing = spectrum[1].x - spectrum[0].x;
        // Coarse by construction: the peak snaps to a bin, so this catches a
        // grossly wrong axis but not a fractional stretch. The axis geometry
        // itself is checked exactly in `spectrum_axis_is_spaced_by_fs_over_dft_size`.
        assert!(
            (peak.x - tone_hz).abs() <= spacing * 0.5,
            "tone landed at {} Hz, expected {tone_hz} Hz (bin spacing {spacing})",
            peak.x
        );
    }

    #[test]
    fn spectrum_axis_is_spaced_by_fs_over_dft_size() {
        // Bins are spaced `fs / dft_size`, start one spacing above DC, and
        // stop one spacing below Nyquist (both DC and Nyquist excluded) —
        // the library's `welch_asd_points` convention.
        let sample_rate: f64 = 1000.0;
        let points: Vec<Point> = (0..16_384)
            .map(|index| {
                let t = index as f64 / sample_rate;
                Point {
                    x: t,
                    y: (std::f64::consts::TAU * 400.0 * t).sin(),
                }
            })
            .collect();

        let spectrum = fft_points(&points, sample_rate, DetrendMethod::None);
        // The library keeps bins 1..dft_size/2, so the transform length
        // follows from the output length.
        let dft_size = 2 * (spectrum.len() + 1);
        let expected_spacing = sample_rate / dft_size as f64;

        let spacing = spectrum[1].x - spectrum[0].x;
        assert!(
            (spacing - expected_spacing).abs() < 1e-9,
            "bin spacing {spacing}, expected {expected_spacing}"
        );
        assert!(
            (spectrum[0].x - expected_spacing).abs() < 1e-9,
            "first bin sits one spacing above DC, not at DC"
        );

        let last = spectrum[spectrum.len() - 1].x;
        let expected_last = sample_rate / 2.0 - expected_spacing;
        assert!(
            (last - expected_last).abs() < 1e-9,
            "last bin {last}, expected {expected_last} (one spacing below Nyquist)"
        );
    }

    #[test]
    fn fft_points_returns_a_one_sided_spectral_density() {
        // For white noise the integral of a one-sided PSD over frequency
        // equals the signal's variance. The underlying Welch implementation
        // returns the two-sided form, so `fft_points` folds it; without that
        // every displayed ASD — the FFT plot's axis, the legend's floor
        // readout, and the derived noise-floor channel alike — would sit a
        // factor of sqrt(2) below the value a `units/sqrt(Hz)` figure denotes.
        let sample_rate: f64 = 1000.0;
        let mut gauss = gaussian_noise(0x9E3779B97F4A7C15);
        let points: Vec<Point> = (0..20_000)
            .map(|index| Point {
                x: index as f64 / sample_rate,
                y: 0.5 * gauss(),
            })
            .collect();

        let mean = points.iter().map(|point| point.y).sum::<f64>() / points.len() as f64;
        let variance = points
            .iter()
            .map(|point| (point.y - mean).powi(2))
            .sum::<f64>()
            / points.len() as f64;

        let spectrum = fft_points(&points, sample_rate, DetrendMethod::None);
        let df = spectrum[1].x - spectrum[0].x;
        let integrated: f64 = spectrum.iter().map(|point| point.y * point.y * df).sum();

        let ratio = integrated / variance;
        assert!(
            (0.97..1.03).contains(&ratio),
            "spectral density convention changed: integral/variance = {ratio}"
        );
    }

    /// Box-Muller over a xorshift stream: repeatable normal noise for tests
    /// without pulling in an RNG dependency.
    fn gaussian_noise(seed: u64) -> impl FnMut() -> f64 {
        let mut state = seed;
        move || {
            let mut next = || {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                (state >> 11) as f64 / (1u64 << 53) as f64
            };
            let u1: f64 = next().max(1e-12);
            let u2: f64 = next();
            (-2.0 * u1.ln()).sqrt() * (std::f64::consts::TAU * u2).cos()
        }
    }

    #[test]
    fn parses_the_json_commands_the_app_encodes() {
        // Captured verbatim from Swift's JSONEncoder. These strings are the
        // contract between the two sides; if a field is renamed on either
        // side, this test is what notices.
        let json = r#"{"panes":[{"columns":[{"columnIndex":2,"route":"/0","streamId":1},{"columnIndex":2,"derivation":"noiseFloor","route":"/0","streamId":1}],"id":0,"view":{"decimationMethod":"fpcs","detrend":"quadratic","fftLogX":true,"fftLogY":true,"logY":false,"mode":"timeseries","plotWidthPixels":800,"resolutionMultiplier":100,"windowSeconds":10}}],"type":"setPlotPanes"}"#;
        let ClientCommand::SetPlotPanes { panes } = serde_json::from_str(json).unwrap() else {
            panic!("expected SetPlotPanes");
        };
        assert_eq!(panes.len(), 1);
        assert_eq!(panes[0].id, 0);
        assert_eq!(panes[0].view.mode, PlotMode::Timeseries);
        assert_eq!(panes[0].view.decimation_method, DecimationMethod::Fpcs);
        assert_eq!(panes[0].view.detrend, DetrendMethod::Quadratic);
        assert!(!panes[0].view.log_y);
        assert_eq!(panes[0].columns[0], ColumnKeyDto::raw("/0", 1, 2));
        assert_eq!(panes[0].columns[1].derivation, Some(Derivation::NoiseFloor));
        // Same source, different channel.
        assert_eq!(panes[0].columns[1].source(), panes[0].columns[0]);

        let json = r#"{"channels":[{"cadenceSeconds":1,"detrend":"quadratic","key":{"columnIndex":2,"derivation":"noiseFloor","route":"/0","streamId":1},"windowSeconds":10}],"type":"setDerivedChannels"}"#;
        let ClientCommand::SetDerivedChannels { channels } = serde_json::from_str(json).unwrap()
        else {
            panic!("expected SetDerivedChannels");
        };
        assert_eq!(channels.len(), 1);
        assert_eq!(channels[0].kind(), Some(Derivation::NoiseFloor));
        assert_eq!(channels[0].window_seconds, 10.0);
        assert_eq!(channels[0].cadence_seconds, 1.0);
        assert_eq!(channels[0].units("T"), "T/sqrt(Hz)");
        assert_eq!(channels[0].units(""), "1/sqrt(Hz)");

        let json = r#"{"type":"setView","view":{"decimationMethod":"fpcs","detrend":"quadratic","fftLogX":true,"fftLogY":true,"logY":false,"mode":"timeseries","plotWidthPixels":800,"resolutionMultiplier":100,"windowSeconds":10}}"#;
        let ClientCommand::SetView { view } = serde_json::from_str(json).unwrap() else {
            panic!("expected SetView");
        };
        assert_eq!(view.window_seconds, 10.0);
        assert!(!view.log_y);
    }

    #[test]
    fn keeps_raw_column_keys_unchanged_on_the_wire() {
        // Layouts and commands written before derived channels existed carry
        // no `derivation` field; they must still parse, and a raw key must
        // still serialise without one.
        let key: ColumnKeyDto =
            serde_json::from_str(r#"{"route":"/0","streamId":1,"columnIndex":2}"#).unwrap();
        assert_eq!(key, ColumnKeyDto::raw("/0", 1, 2));
        assert!(!key.is_derived());
        assert_eq!(
            serde_json::to_string(&key).unwrap(),
            r#"{"route":"/0","streamId":1,"columnIndex":2}"#
        );
    }

    #[test]
    fn derived_keys_never_resolve_to_their_source_column() {
        let source = ColumnKeyDto::raw("/0".to_string(), 1, 0);
        let derived = ColumnKeyDto {
            derivation: Some(Derivation::NoiseFloor),
            ..source.clone()
        };

        let mut state = ColumnState::new("a".to_string(), "T".to_string(), 10.0);
        state.push_raw(Point { x: 1.0, y: 1.0 }, 1e9);
        let states = HashMap::from([(source.clone(), state)]);

        // The unify fallback matches on stream id and column index, which a
        // derived key shares with its source. It must not serve the source's
        // samples under the derived key.
        assert!(resolve_column_state(&states, &derived).is_none());
        assert!(resolve_column_state(&states, &source).is_some());
    }

    #[test]
    fn derived_columns_do_not_anchor_the_pane_time_window() {
        let source = ColumnKeyDto::raw("/0".to_string(), 1, 0);
        let derived = ColumnKeyDto {
            derivation: Some(Derivation::NoiseFloor),
            ..source.clone()
        };

        // Source runs at 10 Hz out to t=5.0; the derived channel emits once a
        // second and has only reached t=3.0.
        let mut source_state = ColumnState::new("a".to_string(), "T".to_string(), 10.0);
        for index in 0..=50 {
            source_state.push_raw(
                Point {
                    x: index as f64 / 10.0,
                    y: 1.0,
                },
                1e9,
            );
        }
        let mut derived_state =
            ColumnState::new("a noise floor".to_string(), "T/sqrt(Hz)".to_string(), 1.0);
        for index in 0..=3 {
            derived_state.push_raw(
                Point {
                    x: index as f64,
                    y: 1e-12,
                },
                1e9,
            );
        }
        let states = HashMap::from([
            (source.clone(), source_state),
            (derived.clone(), derived_state),
        ]);
        let view = ViewConfig::default();

        // Derived listed first: the window must still track the raw column,
        // or the right edge would advance in one-second steps.
        let panes = vec![derived.clone(), source.clone()];
        let (view_end, _, _) = build_live_timeseries_series(0, &states, &panes, &view, None);
        assert_eq!(view_end, Some(5.0));

        // Derived alone: fall back to the source's clock, not the derived
        // channel's own cadence.
        let panes = vec![derived.clone()];
        let (view_end, _, _) = build_live_timeseries_series(0, &states, &panes, &view, None);
        assert_eq!(view_end, Some(5.0));
    }

    #[test]
    fn derived_channel_waits_for_a_full_window_then_emits_on_cadence() {
        let source = ColumnKeyDto::raw("/0".to_string(), 1, 0);
        let channel = DerivedChannelDto {
            key: ColumnKeyDto {
                derivation: Some(Derivation::NoiseFloor),
                ..source.clone()
            },
            window_seconds: 4.0,
            cadence_seconds: 1.0,
            detrend: DetrendMethod::Mean,
        };

        let sample_rate = 64.0;
        let mut state = ColumnState::new("a".to_string(), "T".to_string(), sample_rate);
        let mut states = HashMap::from([(source.clone(), state.clone())]);
        let mut worker = DerivedWorker::new();

        // Half a window in: the channel exists but must not have emitted.
        for index in 0..(2 * sample_rate as usize) {
            state.push_raw(
                Point {
                    x: index as f64 / sample_rate,
                    y: ((index * 37) % 101) as f64 - 50.0,
                },
                1e9,
            );
        }
        states.insert(source.clone(), state.clone());
        update_derived_channels(&[channel.clone()], &mut states, &mut worker, 1e9);
        assert!(
            states.contains_key(&channel.key),
            "state is created eagerly"
        );
        assert!(states[&channel.key].raw.is_empty(), "no estimate yet");

        // Past a full window, a point lands once the worker reports back.
        for index in (2 * sample_rate as usize)..(6 * sample_rate as usize) {
            state.push_raw(
                Point {
                    x: index as f64 / sample_rate,
                    y: ((index * 37) % 101) as f64 - 50.0,
                },
                1e9,
            );
        }
        states.insert(source.clone(), state.clone());
        update_derived_channels(&[channel.clone()], &mut states, &mut worker, 1e9);
        for _ in 0..200 {
            update_derived_channels(&[channel.clone()], &mut states, &mut worker, 1e9);
            if !states[&channel.key].raw.is_empty() {
                break;
            }
            thread::sleep(Duration::from_millis(5));
        }

        let derived = &states[&channel.key];
        assert_eq!(derived.raw.len(), 1, "one point per cadence interval");
        assert_eq!(derived.units, "T/sqrt(Hz)");
        assert_eq!(derived.sample_rate, 1.0);
        let point = derived.raw.back().copied().unwrap();
        // Stamped at the end of the window it summarises, on the source clock.
        assert!((point.x - state.raw.back().unwrap().x).abs() < 1e-9);
        assert!(point.y > 0.0 && point.y.is_finite());
    }

    #[test]
    fn derived_retention_covers_the_longest_derived_window() {
        let view = ViewConfig {
            window_seconds: 10.0,
            ..ViewConfig::default()
        };
        let panes = default_plot_panes(&view);
        let channel = DerivedChannelDto {
            key: ColumnKeyDto {
                derivation: Some(Derivation::NoiseFloor),
                ..ColumnKeyDto::raw("/0".to_string(), 1, 0)
            },
            window_seconds: 200.0,
            cadence_seconds: 1.0,
            detrend: DetrendMethod::Mean,
        };

        // A 10 s pane would retain 15 s, which a 200 s derived window could
        // never fill.
        assert_eq!(live_retention_seconds_for_panes(&panes, &view, &[]), 15.0);
        assert_eq!(
            live_retention_seconds_for_panes(&panes, &view, &[channel]),
            300.0
        );
    }

    #[test]
    fn plots_series_with_compatible_time_references_together() {
        let key_a = ColumnKeyDto::raw("/0".to_string(), 1, 0);
        let key_b = ColumnKeyDto::raw("/1".to_string(), 1, 0);

        // Clocks differ by a couple of seconds: both fit the 10 s window.
        let mut state_a = ColumnState::new("a".to_string(), "V".to_string(), 1.0);
        let mut state_b = ColumnState::new("b".to_string(), "V".to_string(), 1.0);
        for i in 0..20 {
            state_a.push_raw(
                Point {
                    x: 1000.0 + i as f64,
                    y: 1.0,
                },
                1e9,
            );
            state_b.push_raw(
                Point {
                    x: 1002.5 + i as f64,
                    y: 2.0,
                },
                1e9,
            );
        }
        let states = HashMap::from([(key_a.clone(), state_a), (key_b.clone(), state_b)]);
        let view = ViewConfig::default();

        let pane = vec![key_a.clone(), key_b.clone()];
        let (view_end, series, _) = build_live_timeseries_series(0, &states, &pane, &view, None);
        assert_eq!(view_end, Some(1019.0));
        assert_eq!(series.len(), 2);
        assert!(!series[0].outside_window);
        assert!(!series[1].outside_window);
        assert!(series[0].points.len() > 0);
        assert!(series[1].points.len() > 0);
    }

    #[test]
    fn decodes_string_rpc_replies() {
        assert_eq!(
            bytes_to_json_value(b"SN123\0\0\0", "string<8>"),
            Some(json!("SN123"))
        );
        assert_eq!(bytes_to_json_value(b"", "string"), Some(json!("")));
    }

    #[test]
    fn encodes_and_decodes_bool_metadata_as_uint8() {
        assert_eq!(bytes_to_json_value(&[0], "bool"), Some(json!(false)));
        assert_eq!(bytes_to_json_value(&[7], "bool"), Some(json!(true)));
        assert_eq!(json_to_bytes(Some(json!(false)), "bool").unwrap(), vec![0]);
        assert_eq!(json_to_bytes(Some(json!(true)), "bool").unwrap(), vec![1]);
    }

    #[test]
    fn wraps_capture_readout_for_json_results() {
        let mut data = Vec::new();
        data.extend(1.5f32.to_le_bytes());
        data.extend((-2.0f32).to_le_bytes());

        let readout = CaptureReadout {
            metadata: twinleaf::device::capture::CaptureMetadata {
                size: data.len() as u32,
                blocksize: 8,
                data_type: twinleaf::tio::proto::DataType::Float32,
                length: 2,
                y_calibration: 1.0,
                x_offset: 10.0,
                x_stride: 0.5,
                name: "test.capture".to_string(),
                units: "V".to_string(),
                x_name: "time".to_string(),
                x_units: "s".to_string(),
            },
            data,
        };

        let value = capture_readout_to_json_value(&readout);
        assert_eq!(value["encoding"], json!("capture"));
        assert_eq!(value["bytes"], json!(8));
        assert_eq!(value["metadata"]["name"], json!("test.capture"));
        assert_eq!(value["metadata"]["dataType"], json!("f32"));
        assert!(value["text"].as_str().unwrap().contains("10\t1.5"));
        assert!(value["text"].as_str().unwrap().contains("10.5\t-2"));
    }

    #[test]
    fn resolves_active_column_to_unique_live_route_fallback() {
        let active_key = ColumnKeyDto::raw("/2".to_string(), 1, 0);
        let live_key = ColumnKeyDto::raw("/".to_string(), 1, 0);
        let mut live_state = ColumnState::new("live".to_string(), "V".to_string(), 100.0);
        live_state.push_raw(Point { x: 1.0, y: 2.0 }, 10.0);

        let mut column_states = HashMap::new();
        column_states.insert(
            active_key.clone(),
            ColumnState::new("metadata".to_string(), "V".to_string(), 100.0),
        );
        column_states.insert(live_key.clone(), live_state);

        let resolved_key = resolve_data_key(&column_states, &active_key);
        assert_eq!(resolved_key, Some(live_key));
    }

    #[test]
    fn column_state_extracts_points_by_time_range() {
        let mut state = ColumnState::new("signal".to_string(), "V".to_string(), 100.0);
        for index in 0..10 {
            let value = index as f64;
            state.push_raw(Point { x: value, y: value }, 20.0);
        }

        let points = state.points_between(3.0, 6.0);
        assert_eq!(points.len(), 4);
        assert_eq!(points.first().map(|point| point.x), Some(3.0));
        assert_eq!(points.last().map(|point| point.x), Some(6.0));

        let recent = state.recent_points(2.0);
        assert_eq!(recent.first().map(|point| point.x), Some(7.0));
        assert_eq!(recent.last().map(|point| point.x), Some(9.0));
    }

    #[test]
    fn fft_window_uses_constant_sample_count() {
        let mut state = ColumnState::new("signal".to_string(), "V".to_string(), 10.0);
        for index in 0..=100 {
            let x = index as f64 * 0.1;
            state.push_raw(Point { x, y: x }, 20.0);
        }

        let points = state.fft_window_points(2.0, Some(6.05));
        assert_eq!(points.len(), 20);
        assert!((points.first().unwrap().x - 4.1).abs() < 1e-12);
        assert!((points.last().unwrap().x - 6.0).abs() < 1e-12);

        let scrolled_points = state.fft_window_points(2.0, Some(6.14));
        assert_eq!(scrolled_points.len(), 20);
        assert!((scrolled_points.first().unwrap().x - 4.2).abs() < 1e-12);
        assert!((scrolled_points.last().unwrap().x - 6.1).abs() < 1e-12);
    }

    #[test]
    fn fft_request_uses_displayed_time_window() {
        let key = ColumnKeyDto::raw("/".to_string(), 1, 0);
        let mut state = ColumnState::new("signal".to_string(), "V".to_string(), 1.0);
        for index in 0..=100 {
            let value = index as f64;
            state.push_raw(Point { x: value, y: value }, 200.0);
        }

        let column_states = HashMap::from([(key.clone(), state)]);
        let active_columns = HashSet::from([key]);
        let mut view = ViewConfig::default();
        view.window_seconds = 20.0;

        let request = build_fft_request(7, &column_states, &active_columns, &view, Some(60.0));
        assert_eq!(request.generation, 7);
        assert_eq!(request.window_seconds, 20.0);
        assert_eq!(request.inputs.len(), 1);
        assert_eq!(request.inputs[0].points.len(), 20);
        assert_eq!(
            request.inputs[0].points.first().map(|point| point.x),
            Some(41.0)
        );
        assert_eq!(
            request.inputs[0].points.last().map(|point| point.x),
            Some(60.0)
        );

        let live_request = build_fft_request(8, &column_states, &active_columns, &view, None);
        assert_eq!(live_request.window_seconds, 20.0);
        assert_eq!(live_request.inputs[0].points.len(), 20);
        assert_eq!(
            live_request.inputs[0].points.first().map(|point| point.x),
            Some(81.0)
        );
        assert_eq!(
            live_request.inputs[0].points.last().map(|point| point.x),
            Some(100.0)
        );
    }

    #[test]
    fn live_retention_tracks_display_window() {
        let mut view = ViewConfig::default();
        view.window_seconds = 10.0;
        assert_eq!(live_retention_seconds(&view), 15.0);

        view.window_seconds = 120.0;
        assert_eq!(live_retention_seconds(&view), 180.0);
    }

    #[test]
    fn rebuild_fpcs_discards_stale_ring_after_reselect() {
        let mut view = ViewConfig::default();
        view.window_seconds = 10.0;
        view.plot_width_pixels = 200;
        view.resolution_multiplier = 100;
        view.decimation_method = DecimationMethod::Fpcs;
        let retention = live_retention_seconds(&view);

        // Column selected: raw and FPCS ring fill together for x = 0..5.
        let mut state = ColumnState::new("signal".to_string(), "V".to_string(), 1.0);
        for index in 0..5 {
            let point = Point {
                x: index as f64,
                y: index as f64,
            };
            state.push_raw(point, retention);
            state.process_fpcs_point(0, &view, point);
        }

        // Unselected: the raw buffer keeps filling (process_sample pushes every
        // column), trimming the original x = 0..5 out of retention while the
        // ring stays frozen.
        for index in 5..60 {
            state.push_raw(
                Point {
                    x: index as f64,
                    y: index as f64,
                },
                retention,
            );
        }

        // Reselect rebuilds the ring from the continuous raw buffer.
        state.rebuild_fpcs(0, &view);

        let oldest_raw = state.raw.front().unwrap().x;
        let ring = state.fpcs_for_pane(0).unwrap().points_since(-1.0);
        assert!(!ring.is_empty());
        // No stale points from before the column was unselected — the ring is
        // continuous with the raw buffer, so the trace has no gap.
        assert!(
            ring.iter().all(|point| point.x >= oldest_raw),
            "rebuild kept stale pre-unselect points: oldest_raw={oldest_raw}, ring={:?}",
            ring.iter().map(|point| point.x).collect::<Vec<_>>()
        );
    }

    #[test]
    fn configuring_streaming_fpcs_expands_default_capacity() {
        let mut view = ViewConfig::default();
        view.window_seconds = 10.0;
        view.plot_width_pixels = 200;
        view.resolution_multiplier = 100;

        let mut state = ColumnState::new("signal".to_string(), "V".to_string(), 1.0);
        assert!(state.fpcs_for_pane(0).is_none());

        state.ensure_fpcs_configured(0, &view);
        assert_eq!(
            state.fpcs_for_pane(0).unwrap().capacity,
            target_plot_points(&view)
        );

        for index in 0..100 {
            let point = Point {
                x: index as f64 * 0.01,
                y: index as f64,
            };
            state.push_raw(point, live_retention_seconds(&view));
            state.process_fpcs_point(0, &view, point);
        }

        assert!(state.fpcs_for_pane(0).unwrap().points_since(0.0).len() > 2);
    }

    #[test]
    fn hydrate_fpcs_drops_cache_when_pane_leaves_timeseries() {
        let key = ColumnKeyDto::raw("/".to_string(), 1, 0);
        let mut view = ViewConfig::default();
        view.window_seconds = 10.0;
        view.plot_width_pixels = 200;
        view.resolution_multiplier = 100;
        view.decimation_method = DecimationMethod::Fpcs;

        let mut state = ColumnState::new("signal".to_string(), "V".to_string(), 1.0);
        for index in 0..5 {
            let point = Point {
                x: index as f64,
                y: index as f64,
            };
            state.push_raw(point, live_retention_seconds(&view));
            state.process_fpcs_point(0, &view, point);
        }
        assert!(state.fpcs_for_pane(0).is_some());

        let mut column_states = HashMap::from([(key.clone(), state)]);
        let emitter = Emitter::new();
        let fft_pane = PlotPaneConfig {
            id: 0,
            view: ViewConfig {
                mode: PlotMode::Fft,
                ..view.clone()
            },
            columns: vec![key.clone()],
        };
        hydrate_fpcs(&mut column_states, &[fft_pane], &emitter);
        assert!(column_states.get(&key).unwrap().fpcs_for_pane(0).is_none());

        for index in 5..10 {
            let point = Point {
                x: index as f64,
                y: index as f64,
            };
            column_states
                .get_mut(&key)
                .unwrap()
                .push_raw(point, live_retention_seconds(&view));
        }

        let timeseries_pane = PlotPaneConfig {
            id: 0,
            view: view.clone(),
            columns: vec![key.clone()],
        };
        hydrate_fpcs(&mut column_states, &[timeseries_pane], &emitter);
        let points = column_states
            .get(&key)
            .unwrap()
            .fpcs_for_pane(0)
            .unwrap()
            .points_since(0.0);
        assert!(points.iter().any(|point| point.x >= 5.0));
    }

    #[test]
    fn min_max_decimator_caps_points_and_keeps_peaks() {
        let points: Vec<_> = (0..100)
            .map(|index| Point {
                x: index as f64,
                y: if index == 42 { 100.0 } else { index as f64 },
            })
            .collect();

        let decimated = decimate_min_max_by_x(&points, 10);
        assert!(decimated.len() <= 10);
        assert!(decimated
            .iter()
            .any(|point| point.x == 42.0 && point.y == 100.0));
    }

    #[test]
    fn column_state_tracks_smoothed_display_value() {
        let mut state = ColumnState::new("signal".to_string(), "V".to_string(), 100.0);
        state.push_raw(Point { x: 0.0, y: 0.0 }, 10.0);
        state.push_raw(Point { x: 0.01, y: 100.0 }, 10.0);

        let value = state.display_value.unwrap();
        assert!(value > 0.0);
        assert!(value < 100.0);
    }

    #[test]
    fn column_state_computes_smoothed_display_value_for_view_window() {
        let mut state = ColumnState::new("signal".to_string(), "V".to_string(), 100.0);
        for index in 0..5 {
            let value = index as f64 * 100.0;
            state.push_raw(
                Point {
                    x: index as f64,
                    y: value,
                },
                10.0,
            );
        }

        let view_value = state.display_value_between(2.0, 4.0).unwrap();
        assert!(view_value > 200.0);
        assert!(view_value < 400.0);

        let later_view_value = state.display_value_between(4.0, 4.0).unwrap();
        assert_eq!(later_view_value, 400.0);
    }

    #[test]
    fn smoothed_display_value_skips_non_finite_samples() {
        // A NaN sample must not enter the state; the last good value stays.
        let mut value = Some(10.0);
        let mut value_x = Some(0.0);
        update_smoothed_display_value(
            &mut value,
            &mut value_x,
            Point {
                x: 1.0,
                y: f64::NAN,
            },
        );
        assert_eq!(value, Some(10.0));
        assert_eq!(value_x, Some(0.0));
    }

    #[test]
    fn smoothed_display_value_recovers_from_poisoned_state() {
        // If the state is somehow left non-finite, the first finite sample
        // passes straight through instead of staying poisoned...
        let mut value = Some(f64::NAN);
        let mut value_x = Some(f64::NAN);
        update_smoothed_display_value(&mut value, &mut value_x, Point { x: 1.0, y: 42.0 });
        assert_eq!(value, Some(42.0));
        assert_eq!(value_x, Some(1.0));

        // ...and averaging resumes from that value on the next sample.
        update_smoothed_display_value(&mut value, &mut value_x, Point { x: 1.01, y: 142.0 });
        let averaged = value.unwrap();
        assert!(
            averaged > 42.0 && averaged < 142.0,
            "expected an average between the two samples, got {averaged}"
        );
    }

    #[test]
    fn sorts_device_routes_with_leaves_first_and_hub_last() {
        let mut devices = vec![
            test_device("/"),
            test_device("/hub/leaf-b"),
            test_device("/solo"),
            test_device("/hub"),
            test_device("/hub/leaf-a"),
        ];

        sort_devices_leaf_first_with_root(&mut devices, Some("/"));

        let routes: Vec<_> = devices.iter().map(|device| device.route.as_str()).collect();
        assert_eq!(
            routes,
            vec!["/hub/leaf-a", "/hub/leaf-b", "/solo", "/hub", "/"]
        );
    }

    #[test]
    fn sorts_requested_root_route_last() {
        let mut devices = vec![
            test_device("/hub"),
            test_device("/hub/leaf"),
            test_device("/hub/other"),
        ];

        sort_devices_leaf_first_with_root(&mut devices, Some("/hub"));

        let routes: Vec<_> = devices.iter().map(|device| device.route.as_str()).collect();
        assert_eq!(routes, vec!["/hub/leaf", "/hub/other", "/hub"]);
    }

    #[test]
    fn copied_view_data_is_wide_by_active_channel() {
        let key_1 = ColumnKeyDto::raw("/".to_string(), 1, 0);
        let key_2 = ColumnKeyDto::raw("/".to_string(), 1, 1);

        let mut ch_1 = ColumnState::new("ch1".to_string(), "V".to_string(), 100.0);
        ch_1.push_raw(Point { x: 0.0, y: 1.0 }, 10.0);
        ch_1.push_raw(Point { x: 1.0, y: 2.0 }, 10.0);

        let mut ch_2 = ColumnState::new("ch2".to_string(), "V".to_string(), 100.0);
        ch_2.push_raw(Point { x: 0.0, y: 10.0 }, 10.0);
        ch_2.push_raw(Point { x: 0.5, y: 11.0 }, 10.0);
        ch_2.push_raw(Point { x: 1.0, y: 12.0 }, 10.0);

        let mut column_states = HashMap::new();
        column_states.insert(key_1.clone(), ch_1);
        column_states.insert(key_2.clone(), ch_2);

        let mut active_columns = HashSet::new();
        active_columns.insert(key_1);
        active_columns.insert(key_2);

        let text = build_view_data_tsv(
            &column_states,
            &active_columns,
            &ViewConfig::default(),
            Some(1.0),
        );

        let lines: Vec<_> = text.lines().collect();
        assert_eq!(lines[0], "time\tch1\tch2");
        assert_eq!(
            lines[1],
            "0.00000000000000000\t1.00000000000000000\t10.00000000000000000"
        );
        assert_eq!(lines[2], "0.50000000000000000\t\t11.00000000000000000");
        assert_eq!(
            lines[3],
            "1.00000000000000000\t2.00000000000000000\t12.00000000000000000"
        );
    }

    #[test]
    fn white_noise_floor_rejects_one_over_f_and_spectral_peaks() {
        let expected_floor = 2.5e-6;
        let points: Vec<Point> = (1..=1024)
            .map(|index| {
                let frequency = index as f64;
                let broadband_variation = 1.0 + 0.08 * (frequency * 0.37).sin();
                let one_over_f = if index < 320 {
                    expected_floor * 18.0 * (320.0 / frequency - 1.0)
                } else {
                    0.0
                };
                let peak = if index % 47 == 0 || index == 731 {
                    expected_floor * 1_000.0
                } else {
                    0.0
                };
                Point {
                    x: frequency,
                    y: expected_floor * broadband_variation + one_over_f + peak,
                }
            })
            .collect();

        let estimate = estimate_white_noise_floor(&points).unwrap();
        let relative_error = (estimate / expected_floor - 1.0).abs();
        assert!(
            relative_error < 0.05,
            "expected {expected_floor:e}, estimated {estimate:e}"
        );
    }

    #[test]
    fn white_noise_floor_requires_enough_valid_spectrum_bins() {
        let points = vec![Point { x: 1.0, y: 1.0 }; 15];
        assert_eq!(estimate_white_noise_floor(&points), None);
    }

    #[test]
    fn binary_plot_source_streams_deque_range() {
        let key = ColumnKeyDto::raw("/leaf".to_string(), 1, 2);
        let points: VecDeque<_> = [
            Point { x: 0.0, y: 10.0 },
            Point { x: 1.0, y: 11.0 },
            Point { x: 2.0, y: 12.0 },
            Point { x: 3.0, y: 13.0 },
        ]
        .into();
        let source = PlotPointSource::DequeRange {
            points: &points,
            start: 1,
            end: 3,
        };
        let series = [BinaryPlotSeries {
            key: &key,
            sample_rate: 100.0,
            points: source,
            outside_window: false,
            warming_up: false,
            noise_floor: None,
        }];

        assert_eq!(source.len(), 2);
        assert_eq!(
            binary_plot_payload_len(&series).unwrap(),
            20 + 2 + key.route.len() + 1 + 4 + 1 + 8 + 1 + 8 + 4 + 2 * 16
        );

        let mut bytes = Vec::new();
        source.write_to(&mut bytes).unwrap();
        assert_eq!(bytes.len(), 32);
        assert_eq!(f64::from_le_bytes(bytes[0..8].try_into().unwrap()), 1.0);
        assert_eq!(f64::from_le_bytes(bytes[8..16].try_into().unwrap()), 11.0);
        assert_eq!(f64::from_le_bytes(bytes[16..24].try_into().unwrap()), 2.0);
        assert_eq!(f64::from_le_bytes(bytes[24..32].try_into().unwrap()), 12.0);
    }

    fn test_device(route: &str) -> DeviceDto {
        DeviceDto {
            url: "test://device".to_string(),
            route: route.to_string(),
            meta: DeviceMetaDto {
                serial_number: String::new(),
                firmware_hash: String::new(),
                n_streams: 0,
                session_id: 0,
                name: route.to_string(),
            },
            streams: Vec::new(),
            rpcs: Vec::new(),
            full_metadata: None,
        }
    }
}
