use crate::log::LogBuffer;
use anyhow::{bail, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::{
    collections::HashSet,
    sync::{Arc, OnceLock},
    time::Duration,
};
use tokio::sync::{watch, Mutex};
use tokio_tungstenite::{connect_async_with_config, tungstenite::protocol::WebSocketConfig};

const MAX_MESSAGE_BYTES: usize = 1024 * 1024;
const MAX_LINE_BYTES: usize = 64 * 1024;
const TIMEOUT: Duration = Duration::from_secs(5);

fn reserved_vm_ports() -> &'static std::sync::Mutex<HashSet<u16>> {
    static PORTS: OnceLock<std::sync::Mutex<HashSet<u16>>> = OnceLock::new();
    PORTS.get_or_init(Default::default)
}

/// Reserves an identity for a session's device VM port without retaining a
/// listening socket, since an iOS simulator needs to bind that port itself.
#[derive(Debug)]
pub(crate) struct ReservedVmPort {
    port: u16,
}

impl ReservedVmPort {
    pub(crate) fn reserve(requested: Option<u16>) -> Result<Self> {
        let mut ports = reserved_vm_ports()
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(port) = requested.filter(|port| *port != 0) {
            if !ports.insert(port) {
                bail!("Device VM service port {port} is already reserved by another session");
            }
            return Ok(Self { port });
        }
        for _ in 0..128 {
            let listener = std::net::TcpListener::bind(("127.0.0.1", 0))
                .context("Could not select a free VM service port")?;
            let port = listener.local_addr()?.port();
            if ports.insert(port) {
                return Ok(Self { port });
            }
        }
        bail!("Could not select a distinct VM service port for this session")
    }

    pub(crate) fn port(&self) -> u16 {
        self.port
    }
}

impl Drop for ReservedVmPort {
    fn drop(&mut self) {
        reserved_vm_ports()
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&self.port);
    }
}

struct ReadyGuard(watch::Sender<bool>);

impl Drop for ReadyGuard {
    fn drop(&mut self) {
        self.0.send_replace(false);
    }
}

fn websocket_uri(uri: &str) -> Result<url::Url> {
    let mut uri = url::Url::parse(uri).context("Invalid VM service URI")?;
    let scheme = match uri.scheme() {
        "http" => "ws",
        "https" => "wss",
        "ws" => "ws",
        "wss" => "wss",
        _ => bail!("Unsupported VM service URI scheme"),
    };
    uri.set_scheme(scheme)
        .map_err(|_| anyhow::anyhow!("Invalid VM service URI scheme"))?;
    if !uri.path().trim_end_matches('/').ends_with("/ws") {
        uri.set_path(&format!("{}/ws", uri.path().trim_end_matches('/')));
    }
    Ok(uri)
}

#[derive(Default)]
struct Utf8Output {
    tail: Vec<u8>,
    line: String,
    continued: bool,
}

impl Utf8Output {
    fn decode(&mut self, bytes: &[u8]) -> String {
        let mut buffer = std::mem::take(&mut self.tail);
        buffer.extend_from_slice(bytes);
        let mut remaining = buffer.as_slice();
        let mut output = String::new();
        loop {
            match std::str::from_utf8(remaining) {
                Ok(text) => {
                    output.push_str(text);
                    break;
                }
                Err(error) => {
                    // The prefix is validated by from_utf8, including its boundary.
                    output
                        .push_str(std::str::from_utf8(&remaining[..error.valid_up_to()]).unwrap());
                    remaining = &remaining[error.valid_up_to()..];
                    match error.error_len() {
                        Some(length) => {
                            output.push('\u{fffd}');
                            remaining = &remaining[length..];
                        }
                        None => {
                            self.tail.extend_from_slice(remaining);
                            break;
                        }
                    }
                }
            }
        }
        output
    }

    fn lines(&mut self, text: &str, finish: bool) -> Vec<String> {
        self.line.push_str(text);
        let mut lines = vec![];
        let mut start = 0;
        loop {
            let remaining = &self.line[start..];
            match remaining.find('\n') {
                Some(end) if end <= MAX_LINE_BYTES => {
                    if end > 0 || !self.continued {
                        lines.push(remaining[..end].to_owned());
                    }
                    self.continued = false;
                    start += end + 1;
                }
                _ if remaining.len() >= MAX_LINE_BYTES => {
                    let mut end = MAX_LINE_BYTES;
                    while !remaining.is_char_boundary(end) {
                        end -= 1;
                    }
                    lines.push(remaining[..end].to_owned());
                    self.continued = true;
                    start += end;
                }
                _ => break,
            }
        }
        self.line.drain(..start);
        if finish && !self.line.is_empty() {
            lines.push(std::mem::take(&mut self.line));
        }
        lines
    }
}

async fn append_lines(logs: &Mutex<LogBuffer>, category: &str, lines: Vec<String>) {
    if !lines.is_empty() {
        let mut logs = logs.lock().await;
        for line in lines {
            logs.push(category, &line);
        }
    }
}

/// Read only this VM's Dart output, independently of device-wide SDK logging.
pub(crate) async fn collect(
    uri: &str,
    logs: Arc<Mutex<LogBuffer>>,
    ready: watch::Sender<bool>,
) -> Result<()> {
    ready.send_replace(false);
    let ready = ReadyGuard(ready);
    let uri = websocket_uri(uri)?;
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAX_MESSAGE_BYTES))
        .max_frame_size(Some(MAX_MESSAGE_BYTES));
    let (mut socket, _) = tokio::time::timeout(
        TIMEOUT,
        connect_async_with_config(uri.as_str(), Some(config), false),
    )
    .await
    .context("VM log connection timed out")?
    .context("Could not connect to VM log service")?;
    let deadline = tokio::time::Instant::now() + TIMEOUT;
    for (id, stream) in [(1, "Stdout"), (2, "Stderr")] {
        tokio::time::timeout_at(
            deadline,
            socket.send(
                json!({"jsonrpc":"2.0","id":id,"method":"streamListen","params":{"streamId":stream}})
                    .to_string()
                    .into(),
            ),
        )
        .await
        .context("VM log subscription timed out")??;
    }
    let mut subscribed = [false; 2];
    let mut decoders = [Utf8Output::default(), Utf8Output::default()];
    let result: Result<()> = async {
        loop {
            let message = if subscribed.iter().all(|value| *value) {
                socket.next().await
            } else {
                tokio::time::timeout_at(deadline, socket.next())
                    .await
                    .context("VM log subscription timed out")?
            };
            let Some(message) = message else {
                if !subscribed.iter().all(|value| *value) {
                    bail!("VM log service closed before subscriptions completed");
                }
                break;
            };
            let message = message.context("VM log stream failed")?;
            if message.is_close() {
                if !subscribed.iter().all(|value| *value) {
                    bail!("VM log service closed before subscriptions completed");
                }
                break;
            }
            if message.is_ping() || message.is_pong() {
                continue;
            }
            let value: Value = serde_json::from_str(message.to_text()?)
                .context("Invalid VM log protocol message")?;
            if let Some(id @ 1..=2) = value["id"].as_u64() {
                if let Some(error) = value.get("error") {
                    bail!("VM log subscription failed: {error}");
                }
                if value["result"]["type"] != "Success" {
                    bail!("VM log subscription returned no success result");
                }
                subscribed[(id - 1) as usize] = true;
                if subscribed.iter().all(|value| *value) {
                    ready.0.send_replace(true);
                }
            } else if value["method"] == "streamNotify" {
                let index = match value["params"]["streamId"].as_str() {
                    Some("Stdout") => 0,
                    Some("Stderr") => 1,
                    _ => continue,
                };
                let encoded = value["params"]["event"]["bytes"]
                    .as_str()
                    .context("VM log event contains no bytes")?;
                let bytes = STANDARD.decode(encoded).context("Invalid VM log bytes")?;
                let output = decoders[index].decode(&bytes);
                let category = if index == 0 { "stdout" } else { "stderr" };
                // DDS may send history before acknowledging streamListen.
                append_lines(&logs, category, decoders[index].lines(&output, false)).await;
            }
        }
        Ok(())
    }
    .await;
    for (index, decoder) in decoders.iter_mut().enumerate() {
        let replacement = if decoder.tail.is_empty() {
            ""
        } else {
            "\u{fffd}"
        };
        append_lines(
            &logs,
            if index == 0 { "stdout" } else { "stderr" },
            decoder.lines(replacement, true),
        )
        .await;
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::{net::TcpListener, sync::oneshot};
    use tokio_tungstenite::{accept_async, tungstenite::Message};

    #[test]
    fn reserved_ports_are_unique_across_concurrent_sessions_and_release_sockets() {
        let guards: Vec<_> = std::thread::scope(|scope| {
            let tasks: Vec<_> = (0..32)
                .map(|_| scope.spawn(|| ReservedVmPort::reserve(None).unwrap()))
                .collect();
            tasks.into_iter().map(|task| task.join().unwrap()).collect()
        });
        let ports: HashSet<_> = guards.iter().map(ReservedVmPort::port).collect();
        assert_eq!(ports.len(), guards.len());
        assert!(!ports.contains(&0));
        // Reservation must not occupy a socket needed by the simulator VM.
        let listeners: Vec<_> = guards
            .iter()
            .map(|guard| std::net::TcpListener::bind(("127.0.0.1", guard.port())).unwrap())
            .collect();
        drop(listeners);
    }

    #[test]
    fn explicit_reserved_port_rejects_reuse_and_drop_releases_it() {
        let first = ReservedVmPort::reserve(Some(7)).unwrap();
        assert_eq!(first.port(), 7);
        assert!(ReservedVmPort::reserve(Some(7)).is_err());
        drop(first);
        let reused = ReservedVmPort::reserve(Some(7)).unwrap();
        assert_eq!(reused.port(), 7);
    }

    #[test]
    fn explicit_port_does_not_bind_host_and_zero_selects_a_port() {
        let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let guard = ReservedVmPort::reserve(Some(port)).unwrap();
        assert_eq!(guard.port(), port);
        let automatic = ReservedVmPort::reserve(Some(0)).unwrap();
        assert_ne!(automatic.port(), 0);
        assert_ne!(automatic.port(), guard.port());
    }

    fn notification(stream: &str, bytes: &[u8]) -> Message {
        json!({"jsonrpc":"2.0","method":"streamNotify","params":{"streamId":stream,"event":{"bytes":STANDARD.encode(bytes)}}})
            .to_string()
            .into()
    }

    async fn server() -> (String, TcpListener) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        (
            format!("http://{}/token/", listener.local_addr().unwrap()),
            listener,
        )
    }

    async fn requests(socket: &mut tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>) {
        for (id, stream) in [(1, "Stdout"), (2, "Stderr")] {
            let request: Value =
                serde_json::from_str(socket.next().await.unwrap().unwrap().to_text().unwrap())
                    .unwrap();
            assert_eq!(request["id"], id);
            assert_eq!(request["method"], "streamListen");
            assert_eq!(request["params"]["streamId"], stream);
        }
    }

    async fn acknowledge(socket: &mut tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>) {
        for id in [1, 2] {
            socket
                .send(
                    json!({"jsonrpc":"2.0","id":id,"result":{"type":"Success"}})
                        .to_string()
                        .into(),
                )
                .await
                .unwrap();
        }
    }

    #[test]
    fn service_uris_preserve_authentication_and_existing_ws_paths() {
        assert_eq!(
            websocket_uri("http://localhost:123/auth/?x=1")
                .unwrap()
                .as_str(),
            "ws://localhost:123/auth/ws?x=1"
        );
        assert_eq!(
            websocket_uri("ws://localhost:123/auth/ws?x=1")
                .unwrap()
                .as_str(),
            "ws://localhost:123/auth/ws?x=1"
        );
        assert_eq!(
            websocket_uri("https://localhost/auth/").unwrap().scheme(),
            "wss"
        );
        assert!(websocket_uri("file:///tmp/service").is_err());
    }

    #[test]
    fn utf8_decoder_retains_only_incomplete_bytes_and_replaces_invalid_data() {
        let mut decoder = Utf8Output::default();
        assert_eq!(decoder.decode(&[0xe4, 0xbd]), "");
        assert_eq!(decoder.tail.len(), 2);
        assert_eq!(decoder.decode(&[0xa0, 0xff, b'x']), "你\u{fffd}x");
        assert!(decoder.tail.is_empty());
    }

    #[test]
    fn print_text_and_separate_newline_make_one_line_and_keep_blank_lines() {
        let mut decoder = Utf8Output::default();
        assert!(decoder.lines("print text", false).is_empty());
        assert_eq!(decoder.lines("\n", false), ["print text"]);
        assert_eq!(decoder.lines("\n", false), [""]);
        assert!(decoder.lines("partial", false).is_empty());
        assert_eq!(decoder.lines("", true), ["partial"]);
    }

    #[test]
    fn unterminated_output_has_a_bounded_utf8_line_buffer() {
        let mut decoder = Utf8Output::default();
        let output = "你".repeat(MAX_LINE_BYTES);
        let lines = decoder.lines(&output, false);
        assert!(decoder.line.len() < MAX_LINE_BYTES);
        assert!(lines.iter().all(|line| line.len() <= MAX_LINE_BYTES));
        assert_eq!(format!("{}{}", lines.join(""), decoder.line), output);
        assert_eq!(decoder.lines("\n", false).len(), 1);
        assert!(decoder.line.is_empty());
        assert_eq!(decoder.lines(&"x".repeat(MAX_LINE_BYTES), false).len(), 1);
        assert!(decoder.lines("\n", false).is_empty());
        assert_eq!(decoder.lines("\n", false), [""]);
    }

    #[tokio::test]
    async fn subscribes_keeps_history_categories_utf8_and_blank_lines() {
        let (uri, listener) = server().await;
        let (finish, finished) = oneshot::channel();
        let peer = tokio::spawn(async move {
            let mut socket = accept_async(listener.accept().await.unwrap().0)
                .await
                .unwrap();
            requests(&mut socket).await;
            socket
                .send(notification("Stdout", b"history\n"))
                .await
                .unwrap();
            acknowledge(&mut socket).await;
            socket
                .send(notification("Stdout", &[0xe4, 0xbd]))
                .await
                .unwrap();
            socket
                .send(notification("Stderr", b"diagnostic\n"))
                .await
                .unwrap();
            socket
                .send(notification("Stdout", &[0xa0, b'\n']))
                .await
                .unwrap();
            socket.send(notification("Stdout", b"\n")).await.unwrap();
            let _ = finished.await;
            socket.close(None).await.unwrap();
        });
        let logs = Arc::new(Mutex::new(LogBuffer::new(100, 10000)));
        let (ready, mut state) = watch::channel(false);
        let reader_logs = logs.clone();
        let reader = tokio::spawn(async move { collect(&uri, reader_logs, ready).await });
        tokio::time::timeout(TIMEOUT, async {
            while !*state.borrow_and_update() {
                state.changed().await.unwrap();
            }
            loop {
                if logs.lock().await.query(None, 100, None).entries.len() == 4 {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        let page = logs.lock().await.query(None, 100, None);
        assert_eq!(
            page.entries
                .iter()
                .map(|entry| (entry.category.as_str(), entry.text.as_str()))
                .collect::<Vec<_>>(),
            vec![
                ("stdout", "history"),
                ("stderr", "diagnostic"),
                ("stdout", "你"),
                ("stdout", "")
            ]
        );
        finish.send(()).unwrap();
        reader.await.unwrap().unwrap();
        peer.await.unwrap();
        assert!(!*state.borrow());
    }

    #[tokio::test]
    async fn subscription_failure_never_reports_ready() {
        let (uri, listener) = server().await;
        let peer = tokio::spawn(async move {
            let mut socket = accept_async(listener.accept().await.unwrap().0)
                .await
                .unwrap();
            requests(&mut socket).await;
            socket
                .send(
                    json!({"jsonrpc":"2.0","id":1,"error":{"code":100,"message":"unavailable"}})
                        .to_string()
                        .into(),
                )
                .await
                .unwrap();
        });
        let (ready, state) = watch::channel(false);
        let error = collect(&uri, Arc::new(Mutex::new(LogBuffer::new(10, 100))), ready)
            .await
            .unwrap_err();
        assert!(error.to_string().contains("subscription failed"));
        assert!(!*state.borrow());
        peer.await.unwrap();
    }

    #[tokio::test]
    async fn oversized_message_is_rejected_and_resets_ready() {
        let (uri, listener) = server().await;
        let peer = tokio::spawn(async move {
            let mut socket = accept_async(listener.accept().await.unwrap().0)
                .await
                .unwrap();
            requests(&mut socket).await;
            acknowledge(&mut socket).await;
            let _ = socket
                .send(Message::Text("x".repeat(MAX_MESSAGE_BYTES + 1).into()))
                .await;
        });
        let (ready, state) = watch::channel(false);
        let logs = Arc::new(Mutex::new(LogBuffer::new(10, 100)));
        let error = collect(&uri, logs.clone(), ready).await.unwrap_err();
        assert!(format!("{error:#}").contains("too long"));
        assert!(!*state.borrow());
        assert!(logs.lock().await.query(None, 100, None).entries.is_empty());
        peer.await.unwrap();
    }

    #[tokio::test]
    async fn disconnect_during_subscription_is_an_error() {
        let (uri, listener) = server().await;
        let peer = tokio::spawn(async move {
            let mut socket = accept_async(listener.accept().await.unwrap().0)
                .await
                .unwrap();
            requests(&mut socket).await;
            socket.close(None).await.unwrap();
        });
        let (ready, state) = watch::channel(false);
        assert!(
            collect(&uri, Arc::new(Mutex::new(LogBuffer::new(10, 100))), ready)
                .await
                .unwrap_err()
                .to_string()
                .contains("before subscriptions completed")
        );
        assert!(!*state.borrow());
        peer.await.unwrap();
    }

    #[tokio::test]
    async fn missing_subscription_acknowledgement_times_out() {
        let (uri, listener) = server().await;
        let peer = tokio::spawn(async move {
            let mut socket = accept_async(listener.accept().await.unwrap().0)
                .await
                .unwrap();
            requests(&mut socket).await;
            std::future::pending::<()>().await;
        });
        let (ready, state) = watch::channel(false);
        let error = collect(&uri, Arc::new(Mutex::new(LogBuffer::new(10, 100))), ready)
            .await
            .unwrap_err();
        assert!(error.to_string().contains("subscription timed out"));
        assert!(!*state.borrow());
        peer.abort();
    }
}
