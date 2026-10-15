use anyhow::{bail, Context, Result};
use serde_json::Value;

const MAX_LINE_BYTES: usize = 1024 * 1024;

#[derive(Default)]
pub struct DaemonDecoder {
    buffer: Vec<u8>,
}

impl DaemonDecoder {
    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<Value>> {
        let mut values = Vec::new();
        for &byte in bytes {
            if byte != b'\n' {
                if self.buffer.len() >= MAX_LINE_BYTES {
                    bail!("Flutter daemon line exceeds limit");
                }
                self.buffer.push(byte);
                continue;
            }
            let line = std::mem::take(&mut self.buffer);
            let line = std::str::from_utf8(&line)
                .context("Invalid daemon UTF-8")?
                .trim();
            // The SDK can emit diagnostic text on stdout during startup.
            if !line.starts_with('[') || !line.ends_with(']') {
                continue;
            }
            let Ok(Value::Array(messages)) = serde_json::from_str::<Value>(line) else {
                continue;
            };
            values.extend(messages.into_iter().filter(Value::is_object));
        }
        Ok(values)
    }
}

pub fn encode(value: &Value) -> Result<Vec<u8>> {
    let mut message = serde_json::to_vec(&vec![value])?;
    if message.len() > MAX_LINE_BYTES {
        bail!("Flutter daemon message exceeds limit");
    }
    message.push(b'\n');
    Ok(message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn fragments_coalesced_unicode_and_stray_text() {
        let value = json!({"event":"device.added","name":"模拟器"});
        let mut bytes = b"Starting flutter...\n[diagnostic text]\n".to_vec();
        bytes.extend(encode(&value).unwrap());
        bytes.extend(b"[{\"id\":2},{\"id\":3}]\r\n");
        let mut decoder = DaemonDecoder::default();
        let mut result = Vec::new();
        for byte in bytes {
            result.extend(decoder.push(&[byte]).unwrap());
        }
        assert_eq!(result, vec![value, json!({"id":2}), json!({"id":3})]);
    }

    #[test]
    fn bounded_partial_line() {
        assert!(DaemonDecoder::default()
            .push(&vec![b'x'; MAX_LINE_BYTES + 1])
            .is_err());
    }
}
