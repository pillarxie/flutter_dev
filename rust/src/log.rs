use serde::{Deserialize, Serialize};
use std::collections::VecDeque;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct LogEntry {
    pub id: u64,
    pub category: String,
    pub text: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct LogPage {
    pub entries: Vec<LogEntry>,
    pub next_after_id: Option<u64>,
    pub dropped_before_id: Option<u64>,
}

pub struct LogBuffer {
    entries: VecDeque<LogEntry>,
    max_lines: usize,
    max_bytes: usize,
    bytes: usize,
    next_id: u64,
    dropped_before_id: Option<u64>,
}

impl LogBuffer {
    pub fn latest_id(&self) -> u64 {
        self.next_id.saturating_sub(1)
    }

    pub fn new(max_lines: usize, max_bytes: usize) -> Self {
        Self {
            entries: VecDeque::new(),
            max_lines,
            max_bytes,
            bytes: 0,
            next_id: 1,
            dropped_before_id: None,
        }
    }

    pub fn push(&mut self, category: &str, text: &str) -> u64 {
        let mut last = self.next_id.saturating_sub(1);
        for line in text.split('\n') {
            let id = self.next_id;
            self.next_id = self.next_id.saturating_add(1);
            last = id;
            let category = truncate_utf8(category, self.max_bytes);
            let text = truncate_utf8(
                line.trim_end_matches('\r'),
                self.max_bytes.saturating_sub(category.len()),
            );
            self.bytes += category.len() + text.len();
            self.entries.push_back(LogEntry { id, category, text });
            while self.entries.len() > self.max_lines || self.bytes > self.max_bytes {
                if let Some(entry) = self.entries.pop_front() {
                    self.bytes -= entry.category.len() + entry.text.len();
                    self.dropped_before_id = Some(entry.id + 1);
                }
            }
        }
        last
    }

    pub fn query(&self, after_id: Option<u64>, limit: usize, search: Option<&str>) -> LogPage {
        let entries: Vec<_> = self
            .entries
            .iter()
            .filter(|entry| entry.id > after_id.unwrap_or(0))
            .filter(|entry| {
                search.is_none_or(|query| {
                    entry.text.contains(query) || entry.category.contains(query)
                })
            })
            .take(limit.min(1000))
            .cloned()
            .collect();
        LogPage {
            next_after_id: entries.last().map(|entry| entry.id),
            entries,
            dropped_before_id: self.dropped_before_id,
        }
    }
}

fn truncate_utf8(value: &str, max_bytes: usize) -> String {
    let mut end = max_bytes.min(value.len());
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounds_lines_bytes_and_pages() {
        let mut log = LogBuffer::new(2, 12);
        log.push("out", "first\nsecond\nthird");
        let page = log.query(None, 1, None);
        assert_eq!(page.entries.len(), 1);
        assert_eq!(page.entries[0].text, "third");
        assert_eq!(page.dropped_before_id, Some(3));
        assert!(log.query(page.next_after_id, 10, None).entries.is_empty());
    }

    #[test]
    fn truncates_at_utf8_boundaries_and_searches() {
        let mut log = LogBuffer::new(10, 8);
        log.push("o", "你好世界");
        let page = log.query(None, 10, Some("你好"));
        assert_eq!(page.entries[0].text, "你好");
    }
}
