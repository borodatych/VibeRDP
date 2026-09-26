//! The Seam protocol, version 1, as protocol/seam-protocol.md defines it
//!
//! Frames are a little-endian u32 length and a MessagePack map with a "type" key; this module encodes and decodes
//! the subset of MessagePack the protocol uses and gathers frames from the chunks the channel hands out

/// The major version both sides must share
pub const VERSION: u32 = 1;
/// The longest body a frame may carry: an icon fits, a runaway length does not
pub const MAX_BODY: usize = 1 << 20;

/// A value of the MessagePack subset of the protocol
#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Nil,
    Bool(bool),
    Int(i64),
    UInt(u64),
    Float(f64),
    Str(String),
    Bin(Vec<u8>),
    Array(Vec<Value>),
    /// Keys in their order: the protocol writes string keys only
    Map(Vec<(String, Value)>),
}

/// What went wrong with bytes that should hold a frame or a body
#[derive(Debug, PartialEq)]
pub enum Error {
    /// The body ends before the value does
    Truncated,
    /// A MessagePack type outside the subset, or a map key that is not a string
    Unsupported(u8),
    /// A string that is not UTF-8
    BadString,
    /// A frame that says it is longer than MAX_BODY
    TooLong(usize),
    /// Bytes left after the value of a body
    TrailingBytes,
}

impl Value {
    /// The value under a key of a map; None for another value or a missing key
    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Value::Map(entries) => entries.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::Str(s) => Some(s),
            _ => None,
        }
    }

    /// An integer that fits in u64, whichever way MessagePack wrote it
    pub fn as_u64(&self) -> Option<u64> {
        match *self {
            Value::UInt(n) => Some(n),
            Value::Int(n) => u64::try_from(n).ok(),
            _ => None,
        }
    }

    /// An integer that fits in i64, whichever way MessagePack wrote it
    pub fn as_i64(&self) -> Option<i64> {
        match *self {
            Value::Int(n) => Some(n),
            Value::UInt(n) => i64::try_from(n).ok(),
            _ => None,
        }
    }
}

/// Appends the value to the buffer in the shortest MessagePack form
pub fn encode(value: &Value, out: &mut Vec<u8>) {
    match value {
        Value::Nil => out.push(0xc0),
        Value::Bool(b) => out.push(if *b { 0xc3 } else { 0xc2 }),
        Value::UInt(n) => encode_uint(*n, out),
        Value::Int(n) if *n >= 0 => encode_uint(*n as u64, out),
        Value::Int(n) => encode_negative(*n, out),
        Value::Float(f) => {
            out.push(0xcb);
            out.extend_from_slice(&f.to_bits().to_be_bytes());
        }
        Value::Str(s) => {
            let len = s.len();
            if len < 32 {
                out.push(0xa0 | len as u8);
            } else if len <= u8::MAX as usize {
                out.extend_from_slice(&[0xd9, len as u8]);
            } else if len <= u16::MAX as usize {
                out.push(0xda);
                out.extend_from_slice(&(len as u16).to_be_bytes());
            } else {
                out.push(0xdb);
                out.extend_from_slice(&(len as u32).to_be_bytes());
            }
            out.extend_from_slice(s.as_bytes());
        }
        Value::Bin(b) => {
            let len = b.len();
            if len <= u8::MAX as usize {
                out.extend_from_slice(&[0xc4, len as u8]);
            } else if len <= u16::MAX as usize {
                out.push(0xc5);
                out.extend_from_slice(&(len as u16).to_be_bytes());
            } else {
                out.push(0xc6);
                out.extend_from_slice(&(len as u32).to_be_bytes());
            }
            out.extend_from_slice(b);
        }
        Value::Array(items) => {
            encode_length(items.len(), 0x90, 0xdc, out);
            for item in items {
                encode(item, out);
            }
        }
        Value::Map(entries) => {
            encode_length(entries.len(), 0x80, 0xde, out);
            for (key, item) in entries {
                encode(&Value::Str(key.clone()), out);
                encode(item, out);
            }
        }
    }
}

fn encode_uint(n: u64, out: &mut Vec<u8>) {
    if n < 128 {
        out.push(n as u8);
    } else if n <= u8::MAX as u64 {
        out.extend_from_slice(&[0xcc, n as u8]);
    } else if n <= u16::MAX as u64 {
        out.push(0xcd);
        out.extend_from_slice(&(n as u16).to_be_bytes());
    } else if n <= u32::MAX as u64 {
        out.push(0xce);
        out.extend_from_slice(&(n as u32).to_be_bytes());
    } else {
        out.push(0xcf);
        out.extend_from_slice(&n.to_be_bytes());
    }
}

fn encode_negative(n: i64, out: &mut Vec<u8>) {
    if n >= -32 {
        out.push(n as u8);
    } else if n >= i8::MIN as i64 {
        out.extend_from_slice(&[0xd0, n as u8]);
    } else if n >= i16::MIN as i64 {
        out.push(0xd1);
        out.extend_from_slice(&(n as i16).to_be_bytes());
    } else if n >= i32::MIN as i64 {
        out.push(0xd2);
        out.extend_from_slice(&(n as i32).to_be_bytes());
    } else {
        out.push(0xd3);
        out.extend_from_slice(&n.to_be_bytes());
    }
}

/// Arrays and maps: up to 15 entries in the first byte, then 16 and 32 bits of count
fn encode_length(len: usize, fix: u8, wide: u8, out: &mut Vec<u8>) {
    if len < 16 {
        out.push(fix | len as u8);
    } else if len <= u16::MAX as usize {
        out.push(wide);
        out.extend_from_slice(&(len as u16).to_be_bytes());
    } else {
        out.push(wide + 1);
        out.extend_from_slice(&(len as u32).to_be_bytes());
    }
}

/// Reads one value of a body, the whole of it
pub fn decode(bytes: &[u8]) -> Result<Value, Error> {
    let mut reader = Reader { bytes, at: 0 };
    let value = reader.value()?;
    if reader.at != bytes.len() {
        return Err(Error::TrailingBytes);
    }
    Ok(value)
}

struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl Reader<'_> {
    fn take(&mut self, count: usize) -> Result<&[u8], Error> {
        let end = self.at.checked_add(count).ok_or(Error::Truncated)?;
        let slice = self.bytes.get(self.at..end).ok_or(Error::Truncated)?;
        self.at = end;
        Ok(slice)
    }

    fn byte(&mut self) -> Result<u8, Error> {
        Ok(self.take(1)?[0])
    }

    fn be<const N: usize>(&mut self) -> Result<[u8; N], Error> {
        let mut array = [0u8; N];
        array.copy_from_slice(self.take(N)?);
        Ok(array)
    }

    fn length(&mut self, width: usize) -> Result<usize, Error> {
        Ok(match width {
            1 => self.byte()? as usize,
            2 => u16::from_be_bytes(self.be()?) as usize,
            _ => u32::from_be_bytes(self.be()?) as usize,
        })
    }

    fn string(&mut self, len: usize) -> Result<Value, Error> {
        let bytes = self.take(len)?;
        Ok(Value::Str(
            String::from_utf8(bytes.to_vec()).map_err(|_| Error::BadString)?,
        ))
    }

    fn array(&mut self, len: usize) -> Result<Value, Error> {
        // Each entry takes a byte at least: a count beyond the bytes left is a lie, not an allocation
        if len > self.bytes.len() - self.at {
            return Err(Error::Truncated);
        }
        (0..len)
            .map(|_| self.value())
            .collect::<Result<_, _>>()
            .map(Value::Array)
    }

    fn map(&mut self, len: usize) -> Result<Value, Error> {
        if len > self.bytes.len() - self.at {
            return Err(Error::Truncated);
        }
        let mut entries = Vec::with_capacity(len);
        for _ in 0..len {
            let marker = self.bytes.get(self.at).copied().ok_or(Error::Truncated)?;
            let Value::Str(key) = self.value()? else {
                return Err(Error::Unsupported(marker));
            };
            entries.push((key, self.value()?));
        }
        Ok(Value::Map(entries))
    }

    fn value(&mut self) -> Result<Value, Error> {
        let marker = self.byte()?;
        Ok(match marker {
            0x00..=0x7f => Value::UInt(marker as u64),
            0x80..=0x8f => return self.map((marker & 0x0f) as usize),
            0x90..=0x9f => return self.array((marker & 0x0f) as usize),
            0xa0..=0xbf => return self.string((marker & 0x1f) as usize),
            0xc0 => Value::Nil,
            0xc2 => Value::Bool(false),
            0xc3 => Value::Bool(true),
            0xc4..=0xc6 => {
                let len = self.length(1 << (marker - 0xc4))?;
                Value::Bin(self.take(len)?.to_vec())
            }
            0xcb => Value::Float(f64::from_bits(u64::from_be_bytes(self.be()?))),
            0xcc => Value::UInt(self.byte()? as u64),
            0xcd => Value::UInt(u16::from_be_bytes(self.be()?) as u64),
            0xce => Value::UInt(u32::from_be_bytes(self.be()?) as u64),
            0xcf => Value::UInt(u64::from_be_bytes(self.be()?)),
            0xd0 => Value::Int(self.byte()? as i8 as i64),
            0xd1 => Value::Int(i16::from_be_bytes(self.be()?) as i64),
            0xd2 => Value::Int(i32::from_be_bytes(self.be()?) as i64),
            0xd3 => Value::Int(i64::from_be_bytes(self.be()?)),
            0xd9..=0xdb => {
                let len = self.length(1 << (marker - 0xd9))?;
                return self.string(len);
            }
            0xdc | 0xdd => {
                let len = self.length(2 << (marker - 0xdc))?;
                return self.array(len);
            }
            0xde | 0xdf => {
                let len = self.length(2 << (marker - 0xde))?;
                return self.map(len);
            }
            0xe0..=0xff => Value::Int(marker as i8 as i64),
            _ => return Err(Error::Unsupported(marker)),
        })
    }
}

/// A frame of a body: its length, then the body
pub fn frame(body: &Value) -> Vec<u8> {
    let mut encoded = Vec::new();
    encode(body, &mut encoded);
    let mut out = Vec::with_capacity(encoded.len() + 4);
    out.extend_from_slice(&(encoded.len() as u32).to_le_bytes());
    out.extend_from_slice(&encoded);
    out
}

/// Gathers frames from the chunks the channel hands out, whatever their borders
#[derive(Default)]
pub struct FrameReader {
    pending: Vec<u8>,
}

impl FrameReader {
    /// Adds a chunk and returns the bodies it completed, in order; an error closes the channel
    pub fn push(&mut self, chunk: &[u8]) -> Result<Vec<Value>, Error> {
        self.pending.extend_from_slice(chunk);
        let mut bodies = Vec::new();
        while let Some(header) = self.pending.get(..4) {
            let len = u32::from_le_bytes(header.try_into().expect("four bytes")) as usize;
            if len > MAX_BODY {
                return Err(Error::TooLong(len));
            }
            if self.pending.len() < 4 + len {
                break;
            }
            bodies.push(decode(&self.pending[4..4 + len])?);
            self.pending.drain(..4 + len);
        }
        Ok(bodies)
    }
}

/// Builds a map body from its type and entries
pub fn message(kind: &str, entries: Vec<(&str, Value)>) -> Value {
    let mut map = vec![("type".to_string(), Value::Str(kind.to_string()))];
    map.extend(entries.into_iter().map(|(k, v)| (k.to_string(), v)));
    Value::Map(map)
}

/// The greeting of the helper: the version, what it can do, and who it is
pub fn hello(capabilities: &[&str], agent: &str) -> Value {
    message(
        "hello",
        vec![
            ("version", Value::UInt(VERSION as u64)),
            (
                "capabilities",
                Value::Array(
                    capabilities
                        .iter()
                        .map(|c| Value::Str(c.to_string()))
                        .collect(),
                ),
            ),
            ("agent", Value::Str(agent.to_string())),
        ],
    )
}

/// A rectangle as the protocol writes it: [x, y, width, height]
pub fn rect(x: i32, y: i32, width: i32, height: i32) -> Value {
    Value::Array(
        [x, y, width, height]
            .iter()
            .map(|&n| Value::Int(n as i64))
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every value of the subset makes the round trip
    #[test]
    fn values_round_trip() {
        let values = [
            Value::Nil,
            Value::Bool(true),
            Value::UInt(0),
            Value::UInt(127),
            Value::UInt(128),
            Value::UInt(65_536),
            Value::UInt(u64::MAX),
            Value::Int(-1),
            Value::Int(-33),
            Value::Int(-40_000),
            Value::Int(i64::MIN),
            Value::Float(1.5),
            Value::Str("Книга1 - Excel".into()),
            Value::Str("x".repeat(300)),
            Value::Bin(vec![0x89, 0x50, 0x4e, 0x47]),
            Value::Array((0..20).map(Value::UInt).collect()),
            message(
                "window.create",
                vec![
                    ("id", Value::UInt(132_290)),
                    ("rect", rect(-6016, 0, 1280, 800)),
                ],
            ),
        ];
        for value in values {
            let mut bytes = Vec::new();
            encode(&value, &mut bytes);
            let back = decode(&bytes).expect("decodes");
            assert!(same(&value, &back), "{value:?} came back as {back:?}");
        }
    }

    /// Equal values, a non-negative Int equal to the UInt of it: MessagePack does not tell them apart
    fn same(a: &Value, b: &Value) -> bool {
        match (a, b) {
            (Value::Int(n), Value::UInt(m)) | (Value::UInt(m), Value::Int(n)) => {
                *n >= 0 && *n as u64 == *m
            }
            (Value::Array(x), Value::Array(y)) => {
                x.len() == y.len() && x.iter().zip(y).all(|(a, b)| same(a, b))
            }
            (Value::Map(x), Value::Map(y)) => {
                x.len() == y.len()
                    && x.iter()
                        .zip(y)
                        .all(|((ka, va), (kb, vb))| ka == kb && same(va, vb))
            }
            _ => a == b,
        }
    }

    /// The bytes of the example of the specification, written by hand from the MessagePack format
    #[test]
    fn known_bytes() {
        let mut bytes = Vec::new();
        encode(&message("ping", vec![("seq", Value::UInt(7))]), &mut bytes);
        assert_eq!(bytes, b"\x82\xa4type\xa4ping\xa3seq\x07");
        assert_eq!(
            frame(&message("ping", vec![("seq", Value::UInt(7))]))[..4],
            [16, 0, 0, 0]
        );
    }

    /// Frames come whole whatever the chunks: split in the length, in the body, or two in one chunk
    #[test]
    fn frames_from_any_chunks() {
        let first = frame(&hello(&["windows"], "test"));
        let second = frame(&message("ping", vec![("seq", Value::UInt(1))]));
        let stream: Vec<u8> = [first.clone(), second.clone()].concat();
        for split in 1..stream.len() {
            let mut reader = FrameReader::default();
            let mut bodies = reader.push(&stream[..split]).expect("first part");
            bodies.extend(reader.push(&stream[split..]).expect("second part"));
            assert_eq!(bodies.len(), 2, "split at {split}");
            assert_eq!(bodies[0].get("type").and_then(Value::as_str), Some("hello"));
            assert_eq!(bodies[1].get("seq").and_then(Value::as_u64), Some(1));
        }
    }

    /// A frame longer than the limit, a truncated body and a key that is not a string are errors
    #[test]
    fn bad_input() {
        let mut reader = FrameReader::default();
        let too_long = ((MAX_BODY + 1) as u32).to_le_bytes();
        assert_eq!(reader.push(&too_long), Err(Error::TooLong(MAX_BODY + 1)));
        assert_eq!(decode(&[0xa5, b'a']), Err(Error::Truncated));
        assert_eq!(decode(&[0x81, 0x01, 0x02]), Err(Error::Unsupported(0x01)));
        assert_eq!(decode(&[0xc0, 0xc0]), Err(Error::TrailingBytes));
        assert_eq!(
            decode(&[0xdd, 0xff, 0xff, 0xff, 0xff]),
            Err(Error::Truncated),
            "a lying count"
        );
        assert_eq!(decode(&[0xc1]), Err(Error::Unsupported(0xc1)));
    }
}
