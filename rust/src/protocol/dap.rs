use anyhow::{bail, Context, Result};
use serde_json::{json, Value};

const MAX_HEADER_BYTES: usize = 16 * 1024;
const MAX_BODY_BYTES: usize = 16 * 1024 * 1024;
const MAX_RESPONSE_PREFIX_BYTES: usize = 16 * 1024;

/// DAP lengths count bytes, including when the JSON body contains Unicode.
#[derive(Default)]
pub struct DapDecoder {
    buffer: Vec<u8>,
    body_length: Option<usize>,
    discard: Option<OversizedResponse>,
}

impl DapDecoder {
    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<Value>> {
        let mut messages = Vec::new();
        // Consume large reads incrementally so coalesced messages do not grow the buffer unboundedly.
        for chunk in bytes.chunks(64 * 1024) {
            self.buffer.extend_from_slice(chunk);
            loop {
                if let Some(discard) = self.discard.as_mut() {
                    let consumed = discard.remaining.min(self.buffer.len());
                    discard.consume(&self.buffer[..consumed])?;
                    self.buffer.drain(..consumed);
                    discard.remaining -= consumed;
                    if discard.remaining != 0 {
                        break;
                    }
                    messages.push(self.discard.take().unwrap().finish()?);
                }
                if self.body_length.is_none() {
                    let Some(end) = self.buffer.windows(4).position(|v| v == b"\r\n\r\n") else {
                        if self.buffer.len() > MAX_HEADER_BYTES {
                            bail!("DAP header exceeds limit");
                        }
                        break;
                    };
                    if end > MAX_HEADER_BYTES {
                        bail!("DAP header exceeds limit");
                    }
                    let header =
                        std::str::from_utf8(&self.buffer[..end]).context("Invalid DAP header")?;
                    let mut length = None;
                    for line in header.split("\r\n") {
                        let (name, value) = line.split_once(':').context("Malformed DAP header")?;
                        if name.eq_ignore_ascii_case("Content-Length") {
                            if length.is_some() {
                                bail!("Duplicate DAP Content-Length");
                            }
                            let parsed = value
                                .trim()
                                .parse::<usize>()
                                .context("Invalid DAP Content-Length")?;
                            length = Some(parsed);
                        }
                    }
                    self.body_length = Some(length.context("Missing DAP Content-Length")?);
                    self.buffer.drain(..end + 4);
                }
                let length = self.body_length.unwrap();
                if length > MAX_BODY_BYTES {
                    let prefix = &self.buffer[..self.buffer.len().min(MAX_RESPONSE_PREFIX_BYTES)];
                    if let Some((body_start, envelope)) = oversized_response_prefix(prefix) {
                        self.body_length = None;
                        self.buffer.drain(..body_start);
                        self.discard = Some(OversizedResponse {
                            remaining: length - body_start,
                            envelope,
                            body: BodySkipper::default(),
                        });
                        continue;
                    }
                    if self.buffer.len() >= MAX_RESPONSE_PREFIX_BYTES {
                        bail!("DAP body exceeds limit and has no recognized service response envelope");
                    }
                    break;
                }
                if self.buffer.len() < length {
                    break;
                }
                let value = serde_json::from_slice(&self.buffer[..length])
                    .context("Invalid DAP JSON body")?;
                self.buffer.drain(..length);
                self.body_length = None;
                messages.push(value);
            }
        }
        Ok(messages)
    }
}

struct OversizedResponse {
    remaining: usize,
    envelope: Vec<u8>,
    body: BodySkipper,
}

impl OversizedResponse {
    fn consume(&mut self, bytes: &[u8]) -> Result<()> {
        for &byte in bytes {
            if self.body.finished {
                if self.envelope.len() >= MAX_RESPONSE_PREFIX_BYTES {
                    bail!("Oversized DAP response envelope exceeds limit");
                }
                self.envelope.push(byte);
            } else {
                self.body.push(byte)?;
            }
        }
        Ok(())
    }

    fn finish(self) -> Result<Value> {
        if !self.body.finished {
            bail!("Invalid oversized DAP JSON body");
        }
        let value: Value = serde_json::from_slice(&self.envelope)
            .context("Invalid oversized DAP response envelope")?;
        if value["type"] != "response" || value["command"] != "callService" {
            bail!("DAP body exceeds limit for an unsupported response");
        }
        let request_seq = value["request_seq"]
            .as_u64()
            .context("Invalid oversized DAP response request sequence")?;
        Ok(json!({
            "type": "response",
            "command": "callService",
            "request_seq": request_seq,
            "success": false,
            "message": "Network/service response exceeds 16 MiB; this request cannot be displayed"
        }))
    }
}

#[derive(Clone, Copy)]
enum Container {
    ObjectKey(bool),
    ObjectColon,
    ObjectValue,
    ObjectEnd,
    ArrayValue(bool),
    ArrayEnd,
}

#[derive(Default)]
struct BodySkipper {
    containers: Vec<Container>,
    started: bool,
    in_string: bool,
    string_key: bool,
    escaped: bool,
    unicode_digits: u8,
    token: Vec<u8>,
    finished: bool,
}

impl BodySkipper {
    fn value_finished(&mut self) -> Result<()> {
        match self.containers.last_mut() {
            None => self.finished = true,
            Some(state @ Container::ObjectValue) => *state = Container::ObjectEnd,
            Some(state @ Container::ArrayValue(_)) => *state = Container::ArrayEnd,
            _ => bail!("Invalid oversized DAP JSON value"),
        }
        Ok(())
    }

    fn begin_value(&mut self, byte: u8) -> Result<()> {
        match byte {
            b'{' | b'[' => {
                if self.containers.len() >= 128 {
                    bail!("Oversized DAP JSON nesting exceeds limit");
                }
                self.containers.push(if byte == b'{' {
                    Container::ObjectKey(true)
                } else {
                    Container::ArrayValue(true)
                });
            }
            b'"' => {
                self.in_string = true;
                self.string_key = false;
            }
            b'-' | b'0'..=b'9' | b't' | b'f' | b'n' => self.token.push(byte),
            _ => bail!("Invalid oversized DAP JSON value"),
        }
        Ok(())
    }

    fn push(&mut self, byte: u8) -> Result<()> {
        if self.in_string {
            if self.unicode_digits > 0 {
                if !byte.is_ascii_hexdigit() {
                    bail!("Invalid oversized DAP JSON Unicode escape");
                }
                self.unicode_digits -= 1;
            } else if self.escaped {
                self.escaped = false;
                if byte == b'u' {
                    self.unicode_digits = 4;
                } else if !matches!(byte, b'"' | b'\\' | b'/' | b'b' | b'f' | b'n' | b'r' | b't') {
                    bail!("Invalid oversized DAP JSON escape");
                }
            } else {
                match byte {
                    b'\\' => self.escaped = true,
                    b'"' => {
                        self.in_string = false;
                        if self.string_key {
                            *self.containers.last_mut().unwrap() = Container::ObjectColon;
                        } else {
                            self.value_finished()?;
                        }
                    }
                    0..=31 => bail!("Invalid oversized DAP JSON string"),
                    _ => {}
                }
            }
            return Ok(());
        }
        let whitespace = matches!(byte, b' ' | b'\t' | b'\r' | b'\n');
        if !self.token.is_empty() {
            if !whitespace && !matches!(byte, b',' | b']' | b'}') {
                if self.token.len() >= 128 {
                    bail!("Oversized DAP JSON scalar exceeds limit");
                }
                self.token.push(byte);
                return Ok(());
            }
            let _: Value =
                serde_json::from_slice(&self.token).context("Invalid oversized DAP JSON scalar")?;
            self.token.clear();
            self.value_finished()?;
        }
        if whitespace {
            return Ok(());
        }
        if !self.started {
            self.started = true;
            return self.begin_value(byte);
        }
        match self.containers.last().copied() {
            Some(Container::ObjectKey(allow_end)) => match byte {
                b'"' => {
                    self.in_string = true;
                    self.string_key = true;
                }
                b'}' if allow_end => {
                    self.containers.pop();
                    self.value_finished()?;
                }
                _ => bail!("Invalid oversized DAP JSON object key"),
            },
            Some(Container::ObjectColon) => {
                if byte != b':' {
                    bail!("Invalid oversized DAP JSON object separator");
                }
                *self.containers.last_mut().unwrap() = Container::ObjectValue;
            }
            Some(Container::ObjectValue) => self.begin_value(byte)?,
            Some(Container::ObjectEnd) => match byte {
                b',' => *self.containers.last_mut().unwrap() = Container::ObjectKey(false),
                b'}' => {
                    self.containers.pop();
                    self.value_finished()?;
                }
                _ => bail!("Invalid oversized DAP JSON object ending"),
            },
            Some(Container::ArrayValue(allow_end)) => {
                if byte == b']' && allow_end {
                    self.containers.pop();
                    self.value_finished()?;
                } else {
                    self.begin_value(byte)?;
                }
            }
            Some(Container::ArrayEnd) => match byte {
                b',' => *self.containers.last_mut().unwrap() = Container::ArrayValue(false),
                b']' => {
                    self.containers.pop();
                    self.value_finished()?;
                }
                _ => bail!("Invalid oversized DAP JSON array ending"),
            },
            None => bail!("Invalid oversized DAP JSON body ending"),
        }
        Ok(())
    }
}

fn oversized_response_prefix(prefix: &[u8]) -> Option<(usize, Vec<u8>)> {
    // The SDK serializes seq/type, then body, then command/request_seq/success.
    // Parse a complete root-object prefix and retain the envelope around a null
    // body while streaming past the large JSON value without allocating it.
    for (index, byte) in prefix.iter().enumerate() {
        if *byte != b',' {
            continue;
        }
        let mut envelope = prefix[..index].to_vec();
        envelope.push(b'}');
        let Ok(value) = serde_json::from_slice::<Value>(&envelope) else {
            continue;
        };
        if value["type"] != "response" {
            continue;
        }
        let mut keys =
            serde_json::Deserializer::from_slice(&prefix[index + 1..]).into_iter::<String>();
        if !matches!(keys.next(), Some(Ok(key)) if key == "body") {
            continue;
        }
        let key_end = index + 1 + keys.byte_offset();
        let colon = prefix[key_end..]
            .iter()
            .position(|byte| !byte.is_ascii_whitespace())?;
        if prefix[key_end + colon] != b':' {
            continue;
        }
        let body_start = key_end + colon + 1;
        let mut envelope = prefix[..body_start].to_vec();
        envelope.extend_from_slice(b"null");
        return Some((body_start, envelope));
    }
    None
}

pub fn encode(value: &Value) -> Result<Vec<u8>> {
    let body = serde_json::to_vec(value)?;
    if body.len() > MAX_BODY_BYTES {
        bail!("DAP body exceeds limit");
    }
    let mut message = format!("Content-Length: {}\r\n\r\n", body.len()).into_bytes();
    message.extend(body);
    Ok(message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn every_byte_fragment_and_unicode() {
        let value = json!({"text":"你好 🦀"});
        let encoded = encode(&value).unwrap();
        let mut decoder = DapDecoder::default();
        let mut values = Vec::new();
        for byte in encoded {
            values.extend(decoder.push(&[byte]).unwrap());
        }
        assert_eq!(values, vec![value]);
    }

    #[test]
    fn coalesced_and_partial_frames() {
        let a = json!({"seq":1});
        let b = json!({"seq":2});
        let frame_b = encode(&b).unwrap();
        let mut combined = encode(&a).unwrap();
        combined.extend(&frame_b[..10]);
        let mut decoder = DapDecoder::default();
        assert_eq!(decoder.push(&combined).unwrap(), vec![a]);
        assert_eq!(decoder.push(&frame_b[10..]).unwrap(), vec![b]);
    }

    #[test]
    fn rejects_bad_lengths_and_headers() {
        for header in [
            "Content-Length: -1\r\n\r\n",
            "Other: 1\r\n\r\n",
            "Content-Length: 1\r\nContent-Length: 1\r\n\r\n",
        ] {
            assert!(DapDecoder::default().push(header.as_bytes()).is_err());
        }
        assert!(DapDecoder::default()
            .push(&vec![b'x'; MAX_HEADER_BYTES + 1])
            .is_err());
    }

    #[test]
    fn discards_fragmented_oversized_service_body_and_resumes_next_response() {
        let prefix = b"{\"seq\":1,\"type\":\"response\",\"body\":{\"bytes\":\"";
        let suffix = b"\"},\"command\":\"callService\",\"request_seq\":42,\"success\":true}";
        let length = MAX_BODY_BYTES + 100;
        let header = format!("Content-Length: {length}\r\n\r\n");
        let mut decoder = DapDecoder::default();
        for byte in header.bytes().chain(prefix.iter().copied()) {
            assert!(decoder.push(&[byte]).unwrap().is_empty());
        }
        let mut remaining = length - prefix.len() - suffix.len();
        let chunk = [b'x'; 8192];
        while remaining > 0 {
            let count = remaining.min(chunk.len());
            assert!(decoder.push(&chunk[..count]).unwrap().is_empty());
            assert!(decoder.buffer.len() <= MAX_RESPONSE_PREFIX_BYTES);
            remaining -= count;
        }
        let next = json!({"type":"response","request_seq":43,"command":"threads","success":true,"body":{"threads":[]}});
        let mut tail = suffix.to_vec();
        tail.extend(encode(&next).unwrap());
        let messages = decoder.push(&tail).unwrap();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0]["request_seq"], 42);
        assert_eq!(messages[0]["success"], false);
        assert!(messages[0]["message"].as_str().unwrap().contains("16 MiB"));
        assert_eq!(messages[1], next);
        assert!(decoder.buffer.is_empty());
    }

    #[test]
    fn rejects_unknown_oversized_envelopes_and_body_embedded_fields() {
        for prefix in [
            r#"{"type":"event","command":"callService","request_seq":1,"body":""#,
            r#"{"body":{"type":"response","command":"callService","request_seq":1,"body":""#,
            r#"{"type":"response","command":"callService","request_seq":1,"other":""#,
        ] {
            let mut frame =
                format!("Content-Length: {}\r\n\r\n{prefix}", MAX_BODY_BYTES + 1).into_bytes();
            frame.resize(frame.len() + MAX_RESPONSE_PREFIX_BYTES, b'x');
            assert!(DapDecoder::default().push(&frame).is_err());
        }
    }

    #[test]
    fn oversized_suffix_must_identify_a_valid_service_response() {
        for suffix in [
            r#""},"command":"threads","request_seq":1,"success":true}"#,
            r#""},"command":"callService","request_seq":"1","success":true}"#,
            r#""},"command":"callService","request_seq":1,"success":true"#,
            r#""]},"command":"callService","request_seq":1,"success":true}"#,
        ] {
            let prefix = br#"{"seq":1,"type":"response","body":{"bytes":""#;
            let length = prefix.len() + MAX_BODY_BYTES + suffix.len();
            let mut decoder = DapDecoder::default();
            decoder
                .push(format!("Content-Length: {length}\r\n\r\n").as_bytes())
                .unwrap();
            decoder.push(prefix).unwrap();
            let chunk = [b'x'; 8192];
            for _ in 0..MAX_BODY_BYTES / chunk.len() {
                decoder.push(&chunk).unwrap();
            }
            assert!(decoder.push(suffix.as_bytes()).is_err());
        }
    }

    #[test]
    fn skipped_body_handles_nested_values_and_fragmented_escapes() {
        let mut body = BodySkipper::default();
        for &byte in
            br#" {"a":[{"str":"braces } ], comma, quote \" slash \\ unicode \u1234"}],"b":true}"#
        {
            body.push(byte).unwrap();
        }
        assert!(body.finished);
        for text in [
            br#"{"a":[]} ]"#.as_slice(),
            br#"{"a":"\q"}"#.as_slice(),
            br#"{"a":"\u12x4"}"#.as_slice(),
            br#"{bad}"#.as_slice(),
            br#"{"a":1,}"#.as_slice(),
            br#"{"a":[1,]}"#.as_slice(),
            br#"{"a":tru}"#.as_slice(),
        ] {
            let mut body = BodySkipper::default();
            assert!(text.iter().any(|byte| body.push(*byte).is_err()));
        }
    }
}
