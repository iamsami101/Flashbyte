use crate::frb_generated::StreamSink;
use flutter_rust_bridge::frb;
use serde_json::{json, Value};
use std::cmp;
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{BufReader, BufWriter, ErrorKind, Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};
use uuid::Uuid;

const PROGRESS_INTERVAL: Duration = Duration::from_millis(400);
const TRANSFER_BUFFER_SIZE: usize = 1024 * 1024;
const PONG_FRAME: &[u8] = b"\0\0\0\x0f\0\0\0\0{\"type\":\"pong\"}";

static ENGINE: OnceLock<Mutex<Option<EngineState>>> = OnceLock::new();

#[derive(Clone, Debug)]
pub struct TransferMessage {
    pub status: String,
    pub command: Option<String>,
    pub fatal: Option<bool>,
    pub message: Option<String>,
    pub address: Option<String>,
    pub file_id: Option<String>,
    pub file_name: Option<String>,
    pub file_path: Option<String>,
    pub file_size: Option<i64>,
    pub progress: Option<f64>,
    pub time_taken: Option<String>,
    pub tree_uri: Option<String>,
    pub source_file_path: Option<String>,
    pub peer_name: Option<String>,
    pub peer_device_type: Option<String>,
    pub paused_by: Option<String>,
    pub can_resume: Option<bool>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum RustConnectionMode {
    Host,
    Client,
}

#[derive(Debug)]
enum EngineCommand {
    SendFile(String),
    SendFiles(Vec<String>),
    PauseTransfer { file_id: String, role: String },
    ResumeTransfer { file_id: String, role: String },
    CancelTransfer(String),
    AcceptTransfer(String),
    DeclineTransfer(String),
    CancelOutgoingOffer,
    SetDownloadDirectory(Option<String>),
    Disconnect,
}

#[derive(Debug)]
struct EngineState {
    tx: Sender<EngineCommand>,
    mode: RustConnectionMode,
    connected: Arc<AtomicBool>,
    stop_requested: Arc<AtomicBool>,
}

type SharedWriter = Arc<Mutex<Option<Arc<Mutex<TcpStream>>>>>;
type SharedSocketHandle = Arc<Mutex<Option<TcpStream>>>;

/// Shared transfer bookkeeping used by both the command loop and the reader.
#[frb(ignore)]
#[derive(Default)]
pub struct TransferRegistry {
    pending_offers: Mutex<HashMap<String, PendingOffer>>,
    accepted: Mutex<HashSet<String>>,
    declined: Mutex<HashSet<String>>,
    locally_paused: Mutex<HashMap<String, String>>,
    remotely_paused: Mutex<HashMap<String, String>>,
    locally_cancelled: Mutex<HashSet<String>>,
    remotely_cancelled: Mutex<HashSet<String>>,
    approval_cv: Condvar,
}

struct PendingOffer {
    file_path: String,
    file_name: String,
    file_size: u64,
}

pub fn start_host(
    port: u16,
    download_directory: Option<String>,
    device_name: Option<String>,
    device_type: Option<String>,
    sink: StreamSink<TransferMessage>,
) -> Result<(), String> {
    let _ = disconnect();
    let (tx, rx) = mpsc::channel();
    let connected = Arc::new(AtomicBool::new(false));
    let stop_requested = Arc::new(AtomicBool::new(false));
    let shared_writer = Arc::new(Mutex::new(None));
    let shared_socket = Arc::new(Mutex::new(None));
    let registry = Arc::new(TransferRegistry::default());

    set_engine(EngineState {
        tx,
        mode: RustConnectionMode::Host,
        connected: connected.clone(),
        stop_requested: stop_requested.clone(),
    })?;

    spawn_command_loop(
        rx,
        sink.clone(),
        shared_writer.clone(),
        shared_socket.clone(),
        connected.clone(),
        stop_requested.clone(),
        registry.clone(),
    );

    thread::spawn(move || {
        let worker_sink = sink.clone();
        if let Err(error) = run_host(
            port,
            download_directory,
            device_name,
            device_type,
            worker_sink,
            shared_writer,
            shared_socket,
            connected,
            stop_requested,
            registry,
        ) {
            emit_error(&sink, true, error);
            clear_engine();
        }
    });

    Ok(())
}

pub fn connect_to_host(
    host: String,
    port: u16,
    download_directory: Option<String>,
    device_name: Option<String>,
    device_type: Option<String>,
    sink: StreamSink<TransferMessage>,
) -> Result<(), String> {
    let _ = disconnect();
    let (tx, rx) = mpsc::channel();
    let connected = Arc::new(AtomicBool::new(false));
    let stop_requested = Arc::new(AtomicBool::new(false));
    let shared_writer = Arc::new(Mutex::new(None));
    let shared_socket = Arc::new(Mutex::new(None));
    let registry = Arc::new(TransferRegistry::default());

    set_engine(EngineState {
        tx,
        mode: RustConnectionMode::Client,
        connected: connected.clone(),
        stop_requested: stop_requested.clone(),
    })?;

    spawn_command_loop(
        rx,
        sink.clone(),
        shared_writer.clone(),
        shared_socket.clone(),
        connected.clone(),
        stop_requested.clone(),
        registry.clone(),
    );

    thread::spawn(move || {
        let worker_sink = sink.clone();
        if let Err(error) = run_client(
            host,
            port,
            download_directory,
            device_name,
            device_type,
            worker_sink,
            shared_writer,
            shared_socket,
            connected,
            stop_requested,
            registry,
        ) {
            emit_error(&sink, true, error);
            clear_engine();
        }
    });

    Ok(())
}

pub fn send_file(file_path: String) -> Result<(), String> {
    with_engine_tx(|tx| {
        tx.send(EngineCommand::SendFile(file_path))
            .map_err(|e| e.to_string())
    })
}

pub fn send_files(file_paths: Vec<String>) -> Result<(), String> {
    with_engine_tx(|tx| {
        tx.send(EngineCommand::SendFiles(file_paths))
            .map_err(|e| e.to_string())
    })
}

pub fn pause_transfer(file_id: String, role: String) -> Result<(), String> {
    with_engine_tx(|tx| {
        tx.send(EngineCommand::PauseTransfer { file_id, role })
            .map_err(|e| e.to_string())
    })
}

pub fn resume_transfer(file_id: String, role: String) -> Result<(), String> {
    with_engine_tx(|tx| {
        tx.send(EngineCommand::ResumeTransfer { file_id, role })
            .map_err(|e| e.to_string())
    })
}

pub fn cancel_transfer(file_id: String) -> Result<(), String> {
    with_engine_tx(|tx| {
        tx.send(EngineCommand::CancelTransfer(file_id))
            .map_err(|e| e.to_string())
    })
}

pub fn accept_transfer(file_id: String) -> Result<(), String> {
    with_engine_tx(|tx| {
        tx.send(EngineCommand::AcceptTransfer(file_id))
            .map_err(|e| e.to_string())
    })
}

pub fn decline_transfer(file_id: String) -> Result<(), String> {
    with_engine_tx(|tx| {
        tx.send(EngineCommand::DeclineTransfer(file_id))
            .map_err(|e| e.to_string())
    })
}

pub fn cancel_outgoing_offer() -> Result<(), String> {
    with_engine_tx(|tx| {
        tx.send(EngineCommand::CancelOutgoingOffer)
            .map_err(|e| e.to_string())
    })
}

pub fn set_download_directory(directory: Option<String>) -> Result<(), String> {
    with_engine_tx(|tx| {
        tx.send(EngineCommand::SetDownloadDirectory(directory))
            .map_err(|e| e.to_string())
    })
}

pub fn disconnect() -> Result<(), String> {
    with_engine(|state| {
        state.stop_requested.store(true, Ordering::SeqCst);
        state.connected.store(false, Ordering::SeqCst);
        let tx = state.tx.clone();
        tx.send(EngineCommand::Disconnect)
            .map_err(|e| e.to_string())
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn is_running() -> bool {
    engine_lock()
        .lock()
        .ok()
        .and_then(|state| state.as_ref().map(|_| ()))
        .is_some()
}

#[flutter_rust_bridge::frb(sync)]
pub fn is_hosting() -> bool {
    engine_lock()
        .lock()
        .ok()
        .and_then(|state| {
            state
                .as_ref()
                .map(|engine| matches!(engine.mode, RustConnectionMode::Host))
        })
        .unwrap_or(false)
}

#[flutter_rust_bridge::frb(sync)]
pub fn has_established_connection() -> bool {
    engine_lock()
        .lock()
        .ok()
        .and_then(|state| {
            state
                .as_ref()
                .map(|engine| engine.connected.load(Ordering::SeqCst))
        })
        .unwrap_or(false)
}

// ─── Host / Client runners ────────────────────────────────────────────────

fn run_host(
    port: u16,
    download_directory: Option<String>,
    device_name: Option<String>,
    device_type: Option<String>,
    sink: StreamSink<TransferMessage>,
    shared_writer: SharedWriter,
    shared_socket: SharedSocketHandle,
    connected: Arc<AtomicBool>,
    stop_requested: Arc<AtomicBool>,
    registry: Arc<TransferRegistry>,
) -> Result<(), String> {
    let listener = TcpListener::bind(("0.0.0.0", port)).map_err(|e| e.to_string())?;
    listener.set_nonblocking(true).map_err(|e| e.to_string())?;
    emit(
        &sink,
        TransferMessage {
            status: "hosting".to_string(),
            address: Some("0.0.0.0".to_string()),
            ..message_defaults()
        },
    );

    let stream = loop {
        if stop_requested.load(Ordering::SeqCst) {
            clear_engine();
            return Ok(());
        }
        match listener.accept() {
            Ok((stream, _)) => break stream,
            Err(error) if error.kind() == ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(50));
            }
            Err(error) => return Err(error.to_string()),
        }
    };
    configure_stream(&stream);
    emit_status(&sink, "client_connecting");
    install_socket_handles(&stream, &shared_writer, &shared_socket)?;

    // Send our peer_info first
    send_peer_info(
        &shared_writer,
        device_name.as_deref(),
        device_type.as_deref(),
    )?;

    handle_connection(
        stream,
        download_directory,
        sink,
        shared_writer,
        connected,
        stop_requested,
        registry,
        true, // wait_for_probe
    )
}

fn run_client(
    host: String,
    port: u16,
    download_directory: Option<String>,
    device_name: Option<String>,
    device_type: Option<String>,
    sink: StreamSink<TransferMessage>,
    shared_writer: SharedWriter,
    shared_socket: SharedSocketHandle,
    connected: Arc<AtomicBool>,
    stop_requested: Arc<AtomicBool>,
    registry: Arc<TransferRegistry>,
) -> Result<(), String> {
    if stop_requested.load(Ordering::SeqCst) {
        return Ok(());
    }
    let stream = TcpStream::connect((host.as_str(), port)).map_err(|e| e.to_string())?;
    configure_stream(&stream);
    install_socket_handles(&stream, &shared_writer, &shared_socket)?;
    write_control(&shared_writer, json!({"type": "probe", "tls": false}))?;

    send_peer_info(
        &shared_writer,
        device_name.as_deref(),
        device_type.as_deref(),
    )?;

    handle_connection(
        stream,
        download_directory,
        sink,
        shared_writer,
        connected,
        stop_requested,
        registry,
        true,
    )
}

fn send_peer_info(
    shared_writer: &SharedWriter,
    device_name: Option<&str>,
    device_type: Option<&str>,
) -> Result<(), String> {
    write_control(
        shared_writer,
        json!({
            "type": "peer_info",
            "name": device_name.unwrap_or("Unknown"),
            "deviceType": device_type.unwrap_or("phone"),
        }),
    )
}

// ─── Main connection handler ──────────────────────────────────────────────

fn handle_connection(
    stream: TcpStream,
    download_directory: Option<String>,
    sink: StreamSink<TransferMessage>,
    shared_writer: SharedWriter,
    connected: Arc<AtomicBool>,
    stop_requested: Arc<AtomicBool>,
    registry: Arc<TransferRegistry>,
    wait_for_probe: bool,
) -> Result<(), String> {
    // Set a read timeout so the loop can check stop_requested periodically
    stream.set_read_timeout(Some(Duration::from_millis(500))).map_err(|e| e.to_string())?;
    let mut reader = BufReader::with_capacity(TRANSFER_BUFFER_SIZE, stream.try_clone().map_err(|e| e.to_string())?);
    let mut probe_handled = !wait_for_probe;
    let mut current_download_dir = download_directory;

    // Persistent buffer for the 8-byte frame header, with offset tracking
    // so partial reads across timeouts don't lose bytes.
    let mut frame_header = [0_u8; 8];
    let mut header_offset: usize = 0;

    loop {
        if stop_requested.load(Ordering::SeqCst) {
            clear_writer(&shared_writer);
            clear_engine();
            return Ok(());
        }

        // Read frame header bytes incrementally, preserving offset across timeouts
        while header_offset < 8 {
            match reader.read(&mut frame_header[header_offset..]) {
                Ok(0) => {
                    // Connection closed by peer
                    connected.store(false, Ordering::SeqCst);
                    clear_writer(&shared_writer);
                    if probe_handled {
                        emit_disconnect(&sink);
                    } else {
                        emit_error(
                            &sink,
                            true,
                            "Connection closed before the link was established.".to_string(),
                        );
                    }
                    clear_engine();
                    return Ok(());
                }
                Ok(n) => {
                    header_offset += n;
                }
                Err(error)
                    if error.kind() == ErrorKind::WouldBlock
                        || error.kind() == ErrorKind::TimedOut =>
                {
                    // Check stop_requested during idle waits
                    if stop_requested.load(Ordering::SeqCst) {
                        clear_writer(&shared_writer);
                        clear_engine();
                        return Ok(());
                    }
                    // Don't reset header_offset — keep partial read
                    continue;
                }
                Err(error) if error.kind() == ErrorKind::ConnectionReset => {
                    connected.store(false, Ordering::SeqCst);
                    clear_writer(&shared_writer);
                    if probe_handled {
                        emit_disconnect(&sink);
                    } else {
                        emit_error(
                            &sink,
                            true,
                            "Connection closed before the link was established.".to_string(),
                        );
                    }
                    clear_engine();
                    return Ok(());
                }
                Err(error) => {
                    connected.store(false, Ordering::SeqCst);
                    clear_writer(&shared_writer);
                    if probe_handled {
                        emit_error(
                            &sink,
                            true,
                            format!("Connection lost. The other device disconnected unexpectedly. {error}"),
                        );
                    } else {
                        emit_error(
                            &sink,
                            true,
                            "Connection closed before the link was established. Check the TLS setting on both devices.".to_string(),
                        );
                    }
                    clear_engine();
                    return Ok(());
                }
            }
        }
        header_offset = 0;

        let header_len = u32::from_be_bytes(frame_header[0..4].try_into().unwrap()) as usize;
        let payload_len = u32::from_be_bytes(frame_header[4..8].try_into().unwrap()) as u64;

        // Sanity check to prevent huge allocations from corrupted headers
        if header_len > 1024 * 1024 {
            return Err(format!("Invalid frame header length: {header_len}"));
        }

        let mut header_bytes = vec![0_u8; header_len];
        if let Err(error) = read_exact_resumable(&mut reader, &mut header_bytes, &stop_requested) {
            connected.store(false, Ordering::SeqCst);
            clear_writer(&shared_writer);
            if error == "stop" {
                clear_engine();
                return Ok(());
            }
            emit_error(&sink, true, format!("Failed to read frame metadata: {error}"));
            clear_engine();
            return Ok(());
        }
        let header: Value = serde_json::from_slice(&header_bytes).map_err(|e| e.to_string())?;

        if is_control_frame(&header, payload_len) {
            let is_probe_frame = header.get("type").and_then(Value::as_str) == Some("probe")
                || header.get("ok").is_some();
            if !probe_handled && is_probe_frame {
                probe_handled = true;
                handle_probe_frame(&header, &sink, &shared_writer, &connected)?;
                continue;
            }
            handle_control_frame(
                &header,
                &sink,
                &shared_writer,
                &connected,
                &registry,
                &mut current_download_dir,
            )?;
            continue;
        }

        if !probe_handled {
            probe_handled = true;
        }

        // This is a file data frame (metadata has uuid/name, payload is file bytes)
        receive_file(
            &mut reader,
            header,
            payload_len,
            current_download_dir.as_deref(),
            &sink,
            &shared_writer,
            &registry,
        )?;
    }
}

// ─── Control frame handlers ───────────────────────────────────────────────

fn handle_probe_frame(
    header: &Value,
    sink: &StreamSink<TransferMessage>,
    shared_writer: &SharedWriter,
    connected: &Arc<AtomicBool>,
) -> Result<(), String> {
    if let Some(ok) = header.get("ok").and_then(Value::as_bool) {
        if ok {
            connected.store(true, Ordering::SeqCst);
            emit_status(sink, "connected_to_host");
            return Ok(());
        }
        return Err(header
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("Could not establish the connection.")
            .to_string());
    }
    if header.get("type").and_then(Value::as_str) == Some("probe") {
        let client_wants_tls = header.get("tls").and_then(Value::as_bool).unwrap_or(false);
        if client_wants_tls {
            write_control(
                shared_writer,
                json!({"ok": false, "error": "TLS mismatch: server does not use TLS, client has TLS enabled"}),
            )?;
            return Err("TLS settings do not match on both devices.".to_string());
        }
        write_control(shared_writer, json!({"ok": true, "tls": false}))?;
        connected.store(true, Ordering::SeqCst);
        emit_status(sink, "client_connected");
    }
    Ok(())
}

fn handle_control_frame(
    header: &Value,
    sink: &StreamSink<TransferMessage>,
    shared_writer: &SharedWriter,
    connected: &Arc<AtomicBool>,
    registry: &Arc<TransferRegistry>,
    download_dir: &mut Option<String>,
) -> Result<(), String> {
    let frame_type = header.get("type").and_then(Value::as_str).unwrap_or("");
    match frame_type {
        "ping" => write_static_frame(shared_writer, PONG_FRAME),
        "pong" => Ok(()),
        "peer_info" => {
            emit(
                sink,
                TransferMessage {
                    status: "peer_info".to_string(),
                    peer_name: header.get("name").and_then(Value::as_str).map(str::to_string),
                    peer_device_type: header
                        .get("deviceType")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                    ..message_defaults()
                },
            );
            Ok(())
        }
        "file_offer" => {
            let file_id = header
                .get("uuid")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let file_name = header
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .to_string();
            let file_size = header.get("size").and_then(Value::as_i64).unwrap_or(0);
            emit(
                sink,
                TransferMessage {
                    status: "file_offer".to_string(),
                    file_id: Some(file_id),
                    file_name: Some(file_name),
                    file_size: Some(file_size),
                    ..message_defaults()
                },
            );
            Ok(())
        }
        "file_batch" => {
            let files = header.get("files").and_then(Value::as_array).cloned().unwrap_or_default();
            for file in &files {
                let file_id = file.get("uuid").and_then(Value::as_str).unwrap_or("").to_string();
                let file_name = file.get("name").and_then(Value::as_str).unwrap_or("unknown").to_string();
                let file_size = file.get("size").and_then(Value::as_i64).unwrap_or(0);
                emit(
                    sink,
                    TransferMessage {
                        status: "file_offer".to_string(),
                        file_id: Some(file_id),
                        file_name: Some(file_name),
                        file_size: Some(file_size),
                        ..message_defaults()
                    },
                );
            }
            Ok(())
        }
        "file_transfer_accept" => {
            let file_id = header.get("fileId").and_then(Value::as_str).unwrap_or("").to_string();
            {
                let mut accepted = registry.accepted.lock().unwrap();
                accepted.insert(file_id.clone());
            }
            registry.approval_cv.notify_all();
            emit(
                sink,
                TransferMessage {
                    status: "transfer_accepted".to_string(),
                    file_id: Some(file_id.clone()),
                    ..message_defaults()
                },
            );
            // Now send the actual file data for this offer
            trigger_pending_send(&file_id, sink, shared_writer, registry);
            Ok(())
        }
        "file_transfer_decline" => {
            let file_id = header.get("fileId").and_then(Value::as_str).unwrap_or("").to_string();
            {
                let mut declined = registry.declined.lock().unwrap();
                declined.insert(file_id.clone());
            }
            registry.approval_cv.notify_all();
            emit(
                sink,
                TransferMessage {
                    status: "transfer_declined".to_string(),
                    file_id: Some(file_id.clone()),
                    ..message_defaults()
                },
            );
            emit(
                sink,
                TransferMessage {
                    status: "transfer_cancel_ready".to_string(),
                    file_id: Some(file_id.clone()),
                    ..message_defaults()
                },
            );
            // Clean up pending offer
            registry.pending_offers.lock().unwrap().remove(&file_id);
            Ok(())
        }
        "sender_paused" | "receiver_paused" => {
            let file_id = header.get("fileId").and_then(Value::as_str).unwrap_or("").to_string();
            let paused_by = if frame_type == "sender_paused" { "sender" } else { "receiver" };
            registry.remotely_paused.lock().unwrap().insert(file_id.clone(), paused_by.to_string());
            let can_resume = registry.locally_paused.lock().unwrap().contains_key(&file_id);
            emit(
                sink,
                TransferMessage {
                    status: "transfer_paused".to_string(),
                    file_id: Some(file_id),
                    paused_by: Some(paused_by.to_string()),
                    can_resume: Some(can_resume),
                    ..message_defaults()
                },
            );
            Ok(())
        }
        "sender_resumed" | "receiver_resumed" => {
            let file_id = header.get("fileId").and_then(Value::as_str).unwrap_or("").to_string();
            registry.remotely_paused.lock().unwrap().remove(&file_id);
            let still_paused = registry.locally_paused.lock().unwrap().contains_key(&file_id);
            if !still_paused {
                emit(
                    sink,
                    TransferMessage {
                        status: "transfer_resumed".to_string(),
                        file_id: Some(file_id),
                        ..message_defaults()
                    },
                );
            }
            Ok(())
        }
        "file_transfer_cancel" => {
            let file_id = header.get("fileId").and_then(Value::as_str).unwrap_or("").to_string();
            registry.remotely_cancelled.lock().unwrap().insert(file_id.clone());
            registry.locally_paused.lock().unwrap().remove(&file_id);
            registry.remotely_paused.lock().unwrap().remove(&file_id);
            emit(
                sink,
                TransferMessage {
                    status: "transfer_cancelled".to_string(),
                    file_id: Some(file_id),
                    ..message_defaults()
                },
            );
            Ok(())
        }
        "file_offer_cancelled" => {
            emit_status(sink, "offer_cancelled_by_sender");
            Ok(())
        }
        "file_received_ack" => {
            emit(
                sink,
                TransferMessage {
                    status: "send_complete".to_string(),
                    file_id: header.get("fileId").and_then(Value::as_str).map(str::to_string),
                    file_name: header.get("fileName").and_then(Value::as_str).map(str::to_string),
                    time_taken: header.get("timeTaken").and_then(Value::as_str).map(str::to_string),
                    ..message_defaults()
                },
            );
            Ok(())
        }
        "file_receive_progress" => {
            emit(
                sink,
                TransferMessage {
                    status: "send_progress".to_string(),
                    file_id: header.get("fileId").and_then(Value::as_str).map(str::to_string),
                    progress: header.get("progress").and_then(Value::as_f64),
                    ..message_defaults()
                },
            );
            Ok(())
        }
        "disconnect" => {
            connected.store(false, Ordering::SeqCst);
            clear_writer(shared_writer);
            emit_disconnect(sink);
            clear_engine();
            Ok(())
        }
        "set_download_directory" => {
            *download_dir = header.get("directory").and_then(Value::as_str).map(str::to_string);
            Ok(())
        }
        _ => Ok(()),
    }
}

fn trigger_pending_send(
    file_id: &str,
    sink: &StreamSink<TransferMessage>,
    shared_writer: &SharedWriter,
    registry: &Arc<TransferRegistry>,
) {
    let offer = registry.pending_offers.lock().unwrap().remove(file_id);
    if let Some(offer) = offer {
        if let Err(error) = send_file_over_socket(
            &offer.file_path,
            &offer.file_name,
            file_id,
            &offer.file_size,
            sink,
            shared_writer,
            registry,
        ) {
            emit_error(sink, false, format!("File send error: {error}"));
        }
    }
}

// ─── File sending ─────────────────────────────────────────────────────────

fn send_file_over_socket(
    file_path: &str,
    file_name: &str,
    file_id: &str,
    file_size: &u64,
    sink: &StreamSink<TransferMessage>,
    shared_writer: &SharedWriter,
    registry: &Arc<TransferRegistry>,
) -> Result<(), String> {
    let mut file = File::open(file_path).map_err(|e| e.to_string())?;

    let header = json!({
        "uuid": file_id,
        "name": file_name,
        "size": file_size,
    });

    let writer = current_writer(shared_writer)?;
    let mut stream = writer.lock().map_err(|_| "Socket writer lock poisoned".to_string())?;
    write_frame_header(&mut stream, &header, *file_size)?;

    emit(
        sink,
        TransferMessage {
            status: "send_start".to_string(),
            file_id: Some(file_id.to_string()),
            file_name: Some(file_name.to_string()),
            file_path: Some(file_path.to_string()),
            file_size: Some(*file_size as i64),
            ..message_defaults()
        },
    );

    let mut buffer = vec![0_u8; TRANSFER_BUFFER_SIZE];
    let mut sent: u64 = 0;
    let mut last_progress_at = Instant::now() - PROGRESS_INTERVAL;
    let mut last_percent = u64::MAX;

    loop {
        // Check for local pause
        {
            let paused = registry.locally_paused.lock().unwrap();
            if paused.contains_key(file_id) {
                drop(paused);
                // Wait until resumed or cancelled
                loop {
                    thread::sleep(Duration::from_millis(100));
                    let cancelled = registry.locally_cancelled.lock().unwrap().contains(file_id)
                        || registry.remotely_cancelled.lock().unwrap().contains(file_id);
                    if cancelled {
                        return Ok(());
                    }
                    let paused = registry.locally_paused.lock().unwrap();
                    if !paused.contains_key(file_id) {
                        break;
                    }
                }
            }
        }
        // Check for cancel
        if registry.locally_cancelled.lock().unwrap().contains(file_id)
            || registry.remotely_cancelled.lock().unwrap().contains(file_id)
        {
            return Ok(());
        }

        let bytes_read = file.read(&mut buffer).map_err(|e| e.to_string())?;
        if bytes_read == 0 {
            break;
        }
        stream.write_all(&buffer[..bytes_read]).map_err(|e| e.to_string())?;
        sent += bytes_read as u64;

        // Emit send progress
        let percent = if *file_size == 0 { 100 } else { sent * 100 / file_size };
        if percent != last_percent && last_progress_at.elapsed() >= PROGRESS_INTERVAL {
            last_percent = percent;
            last_progress_at = Instant::now();
            let progress = if *file_size == 0 { 1.0 } else { sent as f64 / *file_size as f64 };
            emit(
                sink,
                TransferMessage {
                    status: "send_progress".to_string(),
                    file_id: Some(file_id.to_string()),
                    progress: Some(progress),
                    ..message_defaults()
                },
            );
        }
    }
    stream.flush().map_err(|e| e.to_string())?;
    Ok(())
}

// ─── File receiving ───────────────────────────────────────────────────────

fn receive_file(
    reader: &mut BufReader<TcpStream>,
    header: Value,
    payload_len: u64,
    download_directory: Option<&str>,
    sink: &StreamSink<TransferMessage>,
    shared_writer: &SharedWriter,
    registry: &Arc<TransferRegistry>,
) -> Result<(), String> {
    let file_id = header
        .get("uuid")
        .and_then(Value::as_str)
        .ok_or("Incoming file frame is missing uuid")?
        .to_string();
    let original_name = header
        .get("name")
        .and_then(Value::as_str)
        .ok_or("Incoming file frame is missing name")?;

    // Check if cancelled
    if registry.locally_cancelled.lock().unwrap().contains(&file_id)
        || registry.remotely_cancelled.lock().unwrap().contains(&file_id)
    {
        // Skip the payload
        skip_bytes(reader, payload_len)?;
        return Ok(());
    }

    let target = create_output_target(download_directory, original_name)?;

    emit(
        sink,
        TransferMessage {
            status: "start".to_string(),
            file_id: Some(file_id.clone()),
            file_name: Some(target.file_name.clone()),
            file_path: Some(target.file_path.to_string_lossy().to_string()),
            file_size: Some(payload_len as i64),
            ..message_defaults()
        },
    );

    let started = Instant::now();
    let mut writer = BufWriter::with_capacity(
        TRANSFER_BUFFER_SIZE,
        File::create(&target.file_path).map_err(|e| e.to_string())?,
    );
    let mut buffer = vec![0_u8; TRANSFER_BUFFER_SIZE];
    let mut remaining = payload_len;
    let mut written: u64 = 0;
    let mut last_progress_at = Instant::now() - PROGRESS_INTERVAL;
    let mut last_percent = u64::MAX;

    while remaining > 0 {
        // Check for pause
        while registry.locally_paused.lock().unwrap().contains_key(&file_id)
            || registry.remotely_paused.lock().unwrap().contains_key(&file_id)
        {
            thread::sleep(Duration::from_millis(100));
            if registry.locally_cancelled.lock().unwrap().contains(&file_id)
                || registry.remotely_cancelled.lock().unwrap().contains(&file_id)
            {
                drop(writer);
                let _ = fs::remove_file(&target.file_path);
                return Ok(());
            }
        }
        // Check for cancel
        if registry.locally_cancelled.lock().unwrap().contains(&file_id)
            || registry.remotely_cancelled.lock().unwrap().contains(&file_id)
        {
            drop(writer);
            let _ = fs::remove_file(&target.file_path);
            return Ok(());
        }

        let bytes_to_read = cmp::min(buffer.len() as u64, remaining) as usize;
        let bytes_read = reader
            .read(&mut buffer[..bytes_to_read])
            .map_err(|e| e.to_string())?;
        if bytes_read == 0 {
            return Err("Connection closed while receiving file.".to_string());
        }
        writer.write_all(&buffer[..bytes_read]).map_err(|e| e.to_string())?;
        remaining -= bytes_read as u64;
        written += bytes_read as u64;

        // Emit receive progress
        let percent = if payload_len == 0 { 100 } else { written * 100 / payload_len };
        if percent != last_percent && last_progress_at.elapsed() >= PROGRESS_INTERVAL {
            last_percent = percent;
            last_progress_at = Instant::now();
            let progress = if payload_len == 0 { 1.0 } else { written as f64 / payload_len as f64 };
            emit(
                sink,
                TransferMessage {
                    status: "progress".to_string(),
                    file_id: Some(file_id.clone()),
                    progress: Some(progress),
                    ..message_defaults()
                },
            );
            // Send progress to peer
            let _ = write_control(
                shared_writer,
                json!({
                    "type": "file_receive_progress",
                    "fileId": file_id,
                    "progress": progress,
                }),
            );
        }
    }

    writer.flush().map_err(|e| e.to_string())?;

    let time_taken = started.elapsed().as_secs().to_string();
    write_control(
        shared_writer,
        json!({
            "type": "file_received_ack",
            "fileId": file_id,
            "fileName": target.file_name,
            "timeTaken": time_taken,
        }),
    )?;
    emit(
        sink,
        TransferMessage {
            status: "completed".to_string(),
            file_id: Some(file_id),
            file_name: Some(target.file_name),
            file_path: Some(target.file_path.to_string_lossy().to_string()),
            time_taken: Some(time_taken),
            ..message_defaults()
        },
    );
    Ok(())
}

fn skip_bytes(reader: &mut BufReader<TcpStream>, count: u64) -> Result<(), String> {
    let mut remaining = count;
    let mut buffer = vec![0_u8; TRANSFER_BUFFER_SIZE];
    while remaining > 0 {
        let to_read = cmp::min(buffer.len() as u64, remaining) as usize;
        let read = reader.read(&mut buffer[..to_read]).map_err(|e| e.to_string())?;
        if read == 0 {
            return Err("Connection closed while skipping bytes.".to_string());
        }
        remaining -= read as u64;
    }
    Ok(())
}

/// Reads exactly `buf.len()` bytes, tolerating read timeouts by retrying.
/// Returns Err("stop") if stop_requested is set, or Err(msg) on real errors.
fn read_exact_resumable(
    reader: &mut BufReader<TcpStream>,
    buf: &mut [u8],
    stop_requested: &AtomicBool,
) -> Result<(), String> {
    let mut offset = 0;
    while offset < buf.len() {
        if stop_requested.load(Ordering::SeqCst) {
            return Err("stop".to_string());
        }
        match reader.read(&mut buf[offset..]) {
            Ok(0) => return Err("Connection closed".to_string()),
            Ok(n) => offset += n,
            Err(error)
                if error.kind() == ErrorKind::WouldBlock
                    || error.kind() == ErrorKind::TimedOut =>
            {
                continue;
            }
            Err(error) => return Err(error.to_string()),
        }
    }
    Ok(())
}

// ─── Command loop ─────────────────────────────────────────────────────────

fn spawn_command_loop(
    rx: Receiver<EngineCommand>,
    sink: StreamSink<TransferMessage>,
    shared_writer: SharedWriter,
    _shared_socket: SharedSocketHandle,
    connected: Arc<AtomicBool>,
    stop_requested: Arc<AtomicBool>,
    registry: Arc<TransferRegistry>,
) {
    thread::spawn(move || {
        while let Ok(command) = rx.recv() {
            match command {
                EngineCommand::SendFile(file_path) => {
                    handle_send_file(&file_path, &sink, &shared_writer, &registry);
                }
                EngineCommand::SendFiles(file_paths) => {
                    for path in file_paths {
                        handle_send_file(&path, &sink, &shared_writer, &registry);
                    }
                }
                EngineCommand::PauseTransfer { file_id, role } => {
                    registry.locally_paused.lock().unwrap().insert(file_id.clone(), role.clone());
                    let control_type = format!("{}_paused", role);
                    let _ = write_control(
                        &shared_writer,
                        json!({"type": control_type, "fileId": file_id}),
                    );
                    let can_resume = true;
                    emit(
                        &sink,
                        TransferMessage {
                            status: "transfer_paused".to_string(),
                            file_id: Some(file_id),
                            paused_by: Some(role),
                            can_resume: Some(can_resume),
                            ..message_defaults()
                        },
                    );
                }
                EngineCommand::ResumeTransfer { file_id, role } => {
                    registry.locally_paused.lock().unwrap().remove(&file_id);
                    let control_type = format!("{}_resumed", role);
                    let _ = write_control(
                        &shared_writer,
                        json!({"type": control_type, "fileId": file_id}),
                    );
                    let still_paused = registry.remotely_paused.lock().unwrap().contains_key(&file_id);
                    if !still_paused {
                        emit(
                            &sink,
                            TransferMessage {
                                status: "transfer_resumed".to_string(),
                                file_id: Some(file_id),
                                ..message_defaults()
                            },
                        );
                    }
                }
                EngineCommand::CancelTransfer(file_id) => {
                    registry.locally_cancelled.lock().unwrap().insert(file_id.clone());
                    registry.locally_paused.lock().unwrap().remove(&file_id);
                    registry.remotely_paused.lock().unwrap().remove(&file_id);
                    let _ = write_control(
                        &shared_writer,
                        json!({"type": "file_transfer_cancel", "fileId": file_id}),
                    );
                    emit(
                        &sink,
                        TransferMessage {
                            status: "transfer_cancelled".to_string(),
                            file_id: Some(file_id),
                            ..message_defaults()
                        },
                    );
                }
                EngineCommand::AcceptTransfer(file_id) => {
                    registry.accepted.lock().unwrap().insert(file_id.clone());
                    registry.declined.lock().unwrap().remove(&file_id);
                    let _ = write_control(
                        &shared_writer,
                        json!({"type": "file_transfer_accept", "fileId": file_id}),
                    );
                    emit(
                        &sink,
                        TransferMessage {
                            status: "transfer_accepted".to_string(),
                            file_id: Some(file_id),
                            ..message_defaults()
                        },
                    );
                }
                EngineCommand::DeclineTransfer(file_id) => {
                    registry.declined.lock().unwrap().insert(file_id.clone());
                    registry.accepted.lock().unwrap().remove(&file_id);
                    registry.locally_cancelled.lock().unwrap().insert(file_id.clone());
                    let _ = write_control(
                        &shared_writer,
                        json!({"type": "file_transfer_decline", "fileId": file_id}),
                    );
                    emit(
                        &sink,
                        TransferMessage {
                            status: "transfer_declined".to_string(),
                            file_id: Some(file_id.clone()),
                            ..message_defaults()
                        },
                    );
                    emit(
                        &sink,
                        TransferMessage {
                            status: "transfer_cancel_ready".to_string(),
                            file_id: Some(file_id),
                            ..message_defaults()
                        },
                    );
                }
                EngineCommand::CancelOutgoingOffer => {
                    let _ = write_control(&shared_writer, json!({"type": "file_offer_cancelled"}));
                    emit_status(&sink, "outgoing_offer_cancelled");
                }
                EngineCommand::SetDownloadDirectory(dir) => {
                    let _ = write_control(
                        &shared_writer,
                        json!({"type": "set_download_directory", "directory": dir}),
                    );
                }
                EngineCommand::Disconnect => {
                    stop_requested.store(true, Ordering::SeqCst);
                    connected.store(false, Ordering::SeqCst);
                    let _ = write_control(&shared_writer, json!({"type": "disconnect"}));
                    // Shutdown the socket so the peer detects disconnection
                    if let Ok(guard) = _shared_socket.lock() {
                        if let Some(stream) = guard.as_ref() {
                            let _ = stream.shutdown(Shutdown::Both);
                        }
                    }
                    clear_writer(&shared_writer);
                    clear_socket_handle(&_shared_socket);
                    emit_disconnect(&sink);
                    clear_engine();
                    break;
                }
            }
        }
    });
}

fn handle_send_file(
    file_path: &str,
    sink: &StreamSink<TransferMessage>,
    shared_writer: &SharedWriter,
    registry: &Arc<TransferRegistry>,
) {
    let path = Path::new(file_path);
    let metadata = match fs::metadata(path) {
        Ok(m) => m,
        Err(e) => {
            emit_error(sink, false, format!("Cannot access file: {e}"));
            return;
        }
    };
    let file_size = metadata.len();
    let file_name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown")
        .to_string();
    let file_id = Uuid::new_v4().to_string();

    // Store as pending offer
    registry.pending_offers.lock().unwrap().insert(
        file_id.clone(),
        PendingOffer {
            file_path: file_path.to_string(),
            file_name: file_name.clone(),
            file_size,
        },
    );

    // Send file_offer control frame
    if let Err(e) = write_control(
        shared_writer,
        json!({
            "type": "file_offer",
            "uuid": file_id,
            "name": file_name,
            "size": file_size,
        }),
    ) {
        registry.pending_offers.lock().unwrap().remove(&file_id);
        emit_error(sink, false, format!("Failed to send file offer: {e}"));
        return;
    }

    emit(
        sink,
        TransferMessage {
            status: "file_offer_sent".to_string(),
            file_id: Some(file_id),
            file_name: Some(file_name),
            file_size: Some(file_size as i64),
            ..message_defaults()
        },
    );
}

// ─── Frame I/O helpers ────────────────────────────────────────────────────

fn write_frame_header(stream: &mut TcpStream, header: &Value, payload_len: u64) -> Result<(), String> {
    let header_bytes = serde_json::to_vec(header).map_err(|e| e.to_string())?;
    write_frame_header_bytes(stream, &header_bytes, payload_len)
}

fn write_frame_header_bytes(stream: &mut TcpStream, header_bytes: &[u8], payload_len: u64) -> Result<(), String> {
    if header_bytes.len() > u32::MAX as usize || payload_len > u32::MAX as u64 {
        return Err("Frame is too large for the current protocol.".to_string());
    }
    let mut frame = Vec::with_capacity(8 + header_bytes.len());
    frame.extend_from_slice(&(header_bytes.len() as u32).to_be_bytes());
    frame.extend_from_slice(&(payload_len as u32).to_be_bytes());
    frame.extend_from_slice(header_bytes);
    stream.write_all(&frame).map_err(|e| e.to_string())
}

fn write_control(shared_writer: &SharedWriter, header: Value) -> Result<(), String> {
    let header_bytes = serde_json::to_vec(&header).map_err(|e| e.to_string())?;
    let writer = current_writer(shared_writer)?;
    let mut stream = writer.lock().map_err(|_| "Socket writer lock poisoned".to_string())?;
    write_frame_header_bytes(&mut stream, &header_bytes, 0)?;
    stream.flush().map_err(|e| e.to_string())
}

fn write_static_frame(shared_writer: &SharedWriter, frame: &[u8]) -> Result<(), String> {
    let writer = current_writer(shared_writer)?;
    let mut stream = writer.lock().map_err(|_| "Socket writer lock poisoned".to_string())?;
    stream.write_all(frame).map_err(|e| e.to_string())?;
    stream.flush().map_err(|e| e.to_string())
}

fn is_control_frame(header: &Value, payload_len: u64) -> bool {
    payload_len == 0 && (header.get("type").is_some() || header.get("ok").is_some())
}

// ─── Socket handle helpers ────────────────────────────────────────────────

fn install_socket_handles(stream: &TcpStream, shared_writer: &SharedWriter, shared_socket: &SharedSocketHandle) -> Result<(), String> {
    let writer = stream.try_clone().map_err(|e| e.to_string())?;
    let shutdown_handle = stream.try_clone().map_err(|e| e.to_string())?;
    *shared_writer.lock().map_err(|_| "Socket writer lock poisoned".to_string())? =
        Some(Arc::new(Mutex::new(writer)));
    *shared_socket.lock().map_err(|_| "Socket handle lock poisoned".to_string())? = Some(shutdown_handle);
    Ok(())
}

fn current_writer(shared_writer: &SharedWriter) -> Result<Arc<Mutex<TcpStream>>, String> {
    shared_writer
        .lock()
        .map_err(|_| "Socket writer lock poisoned".to_string())?
        .as_ref()
        .cloned()
        .ok_or("Socket not connected".to_string())
}

fn clear_writer(shared_writer: &SharedWriter) {
    if let Ok(mut writer) = shared_writer.lock() {
        *writer = None;
    }
}

fn clear_socket_handle(shared_socket: &SharedSocketHandle) {
    if let Ok(mut socket) = shared_socket.lock() {
        *socket = None;
    }
}

fn configure_stream(stream: &TcpStream) {
    let _ = stream.set_nodelay(true);
}

// ─── Output file helpers ──────────────────────────────────────────────────

fn create_output_target(download_directory: Option<&str>, original_name: &str) -> Result<OutputTarget, String> {
    let directory = download_directory
        .filter(|p| !p.is_empty() && !p.starts_with("content://"))
        .map(PathBuf::from)
        .or_else(default_download_directory);
    let directory = directory.ok_or("Could not resolve download directory")?;
    fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
    let file_name = unique_file_name(&directory, original_name);
    Ok(OutputTarget {
        file_path: directory.join(&file_name),
        file_name,
    })
}

fn default_download_directory() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join("Downloads"))
        .or_else(|| std::env::current_dir().ok())
}

fn unique_file_name(directory: &Path, original_name: &str) -> String {
    let original = directory.join(original_name);
    if !original.exists() {
        return original_name.to_string();
    }
    let path = Path::new(original_name);
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or(original_name);
    let extension = path.extension().and_then(|s| s.to_str());
    for counter in 1.. {
        let candidate = match extension {
            Some(ext) if !ext.is_empty() => format!("{stem} ({counter}).{ext}"),
            _ => format!("{stem} ({counter})"),
        };
        if !directory.join(&candidate).exists() {
            return candidate;
        }
    }
    unreachable!()
}

// ─── Engine state helpers ─────────────────────────────────────────────────

fn set_engine(state: EngineState) -> Result<(), String> {
    let mut guard = engine_lock().lock().map_err(|_| "Engine lock poisoned".to_string())?;
    *guard = Some(state);
    Ok(())
}

fn clear_engine() {
    if let Ok(mut guard) = engine_lock().lock() {
        *guard = None;
    }
}

fn with_engine<T>(f: impl FnOnce(&EngineState) -> Result<T, String>) -> Result<T, String> {
    let guard = engine_lock().lock().map_err(|_| "Engine lock poisoned".to_string())?;
    let state = guard.as_ref().ok_or("Rust transfer engine is not running")?;
    f(state)
}

fn with_engine_tx<T>(f: impl FnOnce(&Sender<EngineCommand>) -> Result<T, String>) -> Result<T, String> {
    with_engine(|state| f(&state.tx))
}

fn engine_lock() -> &'static Mutex<Option<EngineState>> {
    ENGINE.get_or_init(|| Mutex::new(None))
}

// ─── Emit helpers ─────────────────────────────────────────────────────────

fn emit_status(sink: &StreamSink<TransferMessage>, status: &str) {
    emit(sink, TransferMessage { status: status.to_string(), ..message_defaults() });
}

fn emit_disconnect(sink: &StreamSink<TransferMessage>) {
    emit(
        sink,
        TransferMessage {
            status: "disconnect".to_string(),
            command: Some("disconnect".to_string()),
            ..message_defaults()
        },
    );
}

fn emit_error(sink: &StreamSink<TransferMessage>, fatal: bool, message: String) {
    emit(
        sink,
        TransferMessage {
            status: "error".to_string(),
            fatal: Some(fatal),
            message: Some(message),
            ..message_defaults()
        },
    );
}

fn emit(sink: &StreamSink<TransferMessage>, message: TransferMessage) {
    let _ = sink.add(message);
}

fn message_defaults() -> TransferMessage {
    TransferMessage {
        status: String::new(),
        command: None,
        fatal: None,
        message: None,
        address: None,
        file_id: None,
        file_name: None,
        file_path: None,
        file_size: None,
        progress: None,
        time_taken: None,
        tree_uri: None,
        source_file_path: None,
        peer_name: None,
        peer_device_type: None,
        paused_by: None,
        can_resume: None,
    }
}

struct OutputTarget {
    file_path: PathBuf,
    file_name: String,
}
