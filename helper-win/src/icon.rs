//! Window icons as the protocol carries them: PNG of straight RGBA, protocol/seam-protocol.md, section 6
//!
//! The encoder writes stored deflate blocks: an icon is at most 256×256, a quarter of a mebibyte raw,
//! which fits a frame without compression and keeps the helper free of dependencies

/// The largest side the protocol takes
pub const MAX_SIDE: u32 = 256;
const SIGNATURE: [u8; 8] = [0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1a, b'\n'];
/// Longest stored deflate block
const STORED_BLOCK: usize = 0xffff;
const ADLER_MODULUS: u32 = 65_521;

/// Straight RGBA from the top-down BGRA rows GetDIBits hands out
///
/// An icon without alpha keeps its transparency in the AND mask instead: a set mask pixel is a transparent one
pub fn rgba(bgra: &[u8], mask: Option<&[u8]>) -> Vec<u8> {
    let has_alpha = bgra.chunks_exact(4).any(|px| px[3] != 0);
    bgra.chunks_exact(4)
        .enumerate()
        .flat_map(|(i, px)| {
            let alpha = match (has_alpha, mask) {
                (true, _) => px[3],
                (false, Some(mask)) if mask.get(i * 4).is_some_and(|&m| m != 0) => 0,
                (false, _) => 0xff,
            };
            [px[2], px[1], px[0], alpha]
        })
        .collect()
}

/// A PNG of RGBA pixels; None for an empty image, one larger than MAX_SIDE, or pixels of another size
pub fn png(width: u32, height: u32, rgba: &[u8]) -> Option<Vec<u8>> {
    let row = width as usize * 4;
    if width == 0
        || height == 0
        || width > MAX_SIDE
        || height > MAX_SIDE
        || rgba.len() != row * height as usize
    {
        return None;
    }
    // Every row starts with filter type 0: the bytes go as they are
    let mut raw = Vec::with_capacity((row + 1) * height as usize);
    for line in rgba.chunks_exact(row) {
        raw.push(0);
        raw.extend_from_slice(line);
    }

    let mut header = Vec::with_capacity(13);
    header.extend_from_slice(&width.to_be_bytes());
    header.extend_from_slice(&height.to_be_bytes());
    // Bit depth 8, colour type 6 (RGBA), deflate, adaptive filtering, no interlace
    header.extend_from_slice(&[8, 6, 0, 0, 0]);

    let mut out = SIGNATURE.to_vec();
    chunk(&mut out, b"IHDR", &header);
    chunk(&mut out, b"IDAT", &zlib_stored(&raw));
    chunk(&mut out, b"IEND", &[]);
    Some(out)
}

fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    let start = out.len();
    out.extend_from_slice(kind);
    out.extend_from_slice(data);
    let crc = crc32(&out[start..]);
    out.extend_from_slice(&crc.to_be_bytes());
}

/// A zlib stream of stored blocks
fn zlib_stored(data: &[u8]) -> Vec<u8> {
    // Deflate with a 32 KiB window, no dictionary; the check bits make the header a multiple of 31
    let mut out = vec![0x78, 0x01];
    let mut blocks = data.chunks(STORED_BLOCK).peekable();
    if blocks.peek().is_none() {
        out.extend_from_slice(&[1, 0, 0, 0xff, 0xff]);
    }
    while let Some(block) = blocks.next() {
        out.push(u8::from(blocks.peek().is_none()));
        let len = block.len() as u16;
        out.extend_from_slice(&len.to_le_bytes());
        out.extend_from_slice(&(!len).to_le_bytes());
        out.extend_from_slice(block);
    }
    out.extend_from_slice(&adler32(data).to_be_bytes());
    out
}

fn adler32(data: &[u8]) -> u32 {
    let (a, b) = data.iter().fold((1u32, 0u32), |(a, b), &byte| {
        let a = (a + u32::from(byte)) % ADLER_MODULUS;
        (a, (b + a) % ADLER_MODULUS)
    });
    (b << 16) | a
}

fn crc32(data: &[u8]) -> u32 {
    !data.iter().fold(!0u32, |crc, &byte| {
        (0..8).fold(crc ^ u32::from(byte), |crc, _| {
            if crc & 1 != 0 {
                (crc >> 1) ^ 0xedb8_8320
            } else {
                crc >> 1
            }
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checksums_match_known_values() {
        assert_eq!(adler32(b"Wikipedia"), 0x11e6_0398);
        assert_eq!(crc32(b"123456789"), 0xcbf4_3926);
        assert_eq!(crc32(b"IEND"), 0xae42_6082);
    }

    #[test]
    fn png_has_signature_header_and_end() {
        let png = png(2, 1, &[255, 0, 0, 255, 0, 0, 255, 128]).unwrap();
        assert_eq!(png[..8], SIGNATURE);
        assert_eq!(&png[12..16], b"IHDR");
        assert_eq!(png[16..24], [0, 0, 0, 2, 0, 0, 0, 1]);
        assert_eq!(
            png[png.len() - 12..],
            [0, 0, 0, 0, b'I', b'E', b'N', b'D', 0xae, 0x42, 0x60, 0x82]
        );
    }

    #[test]
    fn stored_blocks_split_long_data_and_mark_the_last() {
        let data = vec![7u8; STORED_BLOCK + 10];
        let z = zlib_stored(&data);
        assert_eq!(z[2], 0);
        assert_eq!(z[3..5], [0xff, 0xff]);
        let second = 2 + 5 + STORED_BLOCK;
        assert_eq!(z[second], 1);
        assert_eq!(z[second + 1..second + 3], 10u16.to_le_bytes());
        assert_eq!(z.len(), 2 + 5 + STORED_BLOCK + 5 + 10 + 4);
    }

    #[test]
    fn png_refuses_wrong_sizes() {
        assert!(png(0, 1, &[]).is_none());
        assert!(png(MAX_SIDE + 1, 1, &vec![0; (MAX_SIDE as usize + 1) * 4]).is_none());
        assert!(png(2, 2, &[0; 4]).is_none());
    }

    #[test]
    fn alpha_of_the_icon_wins_over_the_mask() {
        let bgra = [10, 20, 30, 200, 1, 2, 3, 0];
        assert_eq!(rgba(&bgra, Some(&[0xff; 8])), [30, 20, 10, 200, 3, 2, 1, 0]);
    }

    #[test]
    fn mask_gives_transparency_to_an_icon_without_alpha() {
        let bgra = [10, 20, 30, 0, 1, 2, 3, 0];
        let mask = [0, 0, 0, 0, 0xff, 0xff, 0xff, 0];
        assert_eq!(rgba(&bgra, Some(&mask)), [30, 20, 10, 255, 3, 2, 1, 0]);
        assert_eq!(rgba(&bgra, None), [30, 20, 10, 255, 3, 2, 1, 255]);
    }
}
