//! RAR 4/5 header inspection. Never decrypts or reads a member's payload.
//! Layouts: RARLAB technote.htm and UnRAR's headers.hpp / arcread.cpp.

pub(in crate::similarity) const MAX_HEADER: usize = (2 << 20) + 7;
pub(in crate::similarity) const MAX_PROBE_BYTES: u64 = 4 << 20;
pub(in crate::similarity) const MAX_BLOCKS: usize = 1_024;

#[derive(Clone, Copy, Debug)]
pub(in crate::similarity) enum Format {
    Rar4,
    Rar5,
}

#[derive(Debug, PartialEq, Eq)]
pub(in crate::similarity) struct Block {
    pub encrypted: bool,
    pub data_bytes: u64,
    pub end: bool,
}

pub(in crate::similarity) fn format(prefix: &[u8]) -> Option<Format> {
    if prefix.starts_with(b"Rar!\x1a\x07\x00") {
        Some(Format::Rar4)
    } else if prefix.starts_with(b"Rar!\x1a\x07\x01\x00") {
        Some(Format::Rar5)
    } else {
        None
    }
}

fn u16_at(bytes: &[u8], offset: usize) -> Option<u16> {
    Some(u16::from_le_bytes(
        bytes.get(offset..offset.checked_add(2)?)?.try_into().ok()?,
    ))
}
fn u32_at(bytes: &[u8], offset: usize) -> Option<u32> {
    Some(u32::from_le_bytes(
        bytes.get(offset..offset.checked_add(4)?)?.try_into().ok()?,
    ))
}

fn vint(bytes: &[u8], offset: &mut usize) -> Option<u64> {
    let mut value = 0u64;
    for shift in (0..70).step_by(7) {
        let byte = *bytes.get(*offset)?;
        *offset += 1;
        if shift == 63 && byte > 1 {
            return None;
        }
        value |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Some(value);
        }
    }
    None
}

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = !0u32;
    for &byte in bytes {
        crc ^= u32::from(byte);
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0xedb88320 & 0u32.wrapping_sub(crc & 1));
        }
    }
    !crc
}

impl Format {
    pub fn signature_bytes(self) -> u64 {
        match self {
            Self::Rar4 => 7,
            Self::Rar5 => 8,
        }
    }

    /// Seven bytes suffice to read either format's declared header length.
    pub fn header_bytes(self, prefix: &[u8]) -> Option<usize> {
        let length = match self {
            Self::Rar4 => usize::from(u16_at(prefix, 5)?),
            Self::Rar5 => {
                let mut offset = 4;
                let size = usize::try_from(vint(prefix, &mut offset)?).ok()?;
                if offset > 7 || size < 2 {
                    return None;
                }
                offset.checked_add(size)?
            }
        };
        (7..=MAX_HEADER).contains(&length).then_some(length)
    }

    pub fn block(self, bytes: &[u8], first: bool) -> Option<Block> {
        if self.header_bytes(bytes)? != bytes.len() {
            return None;
        }
        match self {
            Self::Rar4 => rar4(bytes, first),
            Self::Rar5 => rar5(bytes, first),
        }
    }
}

fn rar4(bytes: &[u8], first: bool) -> Option<Block> {
    if crc32(&bytes[2..]) as u16 != u16_at(bytes, 0)? {
        return None;
    }
    let kind = bytes[2];
    let flags = u16_at(bytes, 3)?;
    if first && kind != 0x73 {
        return None;
    }
    let mut data_bytes = if flags & 0x8000 != 0 {
        u64::from(u32_at(bytes, 7)?)
    } else {
        0
    };
    let encrypted = match kind {
        0x73 => {
            if bytes.len() < 13 {
                return None;
            }
            flags & 0x0080 != 0 // MHD_PASSWORD: the following headers are encrypted.
        }
        0x74 | 0x7a => {
            if bytes.len() < 32 {
                return None;
            }
            data_bytes = u64::from(u32_at(bytes, 7)?);
            let base = if flags & 0x0100 != 0 {
                data_bytes |= u64::from(u32_at(bytes, 32)?) << 32;
                40
            } else {
                32
            };
            let name_bytes = usize::from(u16_at(bytes, 26)?);
            if base + name_bytes + if flags & 0x0400 != 0 { 8 } else { 0 } > bytes.len() {
                return None;
            }
            flags & 0x0004 != 0 // LHD_PASSWORD: this file/service data is encrypted.
        }
        0x75..=0x79 | 0x7b => false,
        _ => return None,
    };
    Some(Block {
        encrypted,
        data_bytes,
        end: kind == 0x7b,
    })
}

fn crypto(bytes: &[u8], with_iv: bool) -> Option<()> {
    let mut offset = 0;
    if vint(bytes, &mut offset)? != 0 {
        return None;
    } // Defined AES-256 layout.
    let flags = vint(bytes, &mut offset)?;
    let required =
        offset + 1 + 16 + if with_iv { 16 } else { 0 } + if flags & 1 != 0 { 12 } else { 0 };
    (bytes.len() >= required).then_some(())
}

fn rar5(bytes: &[u8], first: bool) -> Option<Block> {
    if crc32(&bytes[4..]) != u32_at(bytes, 0)? {
        return None;
    }
    let mut offset = 4;
    vint(bytes, &mut offset)?; // Validated header size.
    let kind = vint(bytes, &mut offset)?;
    let flags = vint(bytes, &mut offset)?;
    if first && kind != 1 && kind != 4 {
        return None;
    }
    let extra = if flags & 1 != 0 {
        usize::try_from(vint(bytes, &mut offset)?).ok()?
    } else {
        0
    };
    let data_bytes = if flags & 2 != 0 {
        vint(bytes, &mut offset)?
    } else {
        0
    };
    let end = bytes.len().checked_sub(extra)?;
    let body = bytes.get(offset..end)?;
    let mut encrypted = false;
    if kind == 4 {
        crypto(body, false)?;
        encrypted = true;
    } else if kind == 2 || kind == 3 {
        let mut cursor = 0;
        let file_flags = vint(body, &mut cursor)?;
        vint(body, &mut cursor)?; // Unpacked size.
        vint(body, &mut cursor)?; // Attributes.
        if file_flags & 2 != 0 {
            cursor = cursor.checked_add(4)?;
        }
        if file_flags & 4 != 0 {
            cursor = cursor.checked_add(4)?;
        }
        vint(body, &mut cursor)?; // Compression information.
        vint(body, &mut cursor)?; // Host OS.
        let name = usize::try_from(vint(body, &mut cursor)?).ok()?;
        if cursor.checked_add(name)? > body.len() {
            return None;
        }
        let mut cursor = end;
        while cursor < bytes.len() {
            let size = usize::try_from(vint(bytes, &mut cursor)?).ok()?;
            let record_end = cursor.checked_add(size)?;
            let record = bytes.get(cursor..record_end)?;
            let mut field = 0;
            if vint(record, &mut field)? == 1 {
                crypto(&record[field..], true)?;
                encrypted = true;
            }
            cursor = record_end;
        }
    } else if kind == 1 || kind == 5 {
        let mut cursor = 0;
        vint(body, &mut cursor)?; // Main/archive-end flags.
    }
    Some(Block {
        encrypted,
        data_bytes,
        end: kind == 5,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{engine::general_purpose::STANDARD, Engine as _};

    fn protected(bytes: &[u8]) -> Option<bool> {
        let format = format(bytes)?;
        let mut offset = format.signature_bytes() as usize;
        let mut first = true;
        while offset < bytes.len() {
            let length = format.header_bytes(bytes.get(offset..)?)?;
            let block = format.block(bytes.get(offset..offset.checked_add(length)?)?, first)?;
            let next = offset
                .checked_add(length)?
                .checked_add(usize::try_from(block.data_bytes).ok()?)?;
            if next > bytes.len() {
                return None;
            }
            if block.encrypted {
                return Some(true);
            }
            if block.end {
                return Some(false);
            }
            offset = next;
            first = false;
        }
        Some(false)
    }

    #[test]
    fn real_rar4_and_rar5_encryption_headers_and_mixed_members() {
        for sample in [
            include_str!("../scripts/fixtures/similarity-rar/rar4-data.rar.b64"),
            include_str!("../scripts/fixtures/similarity-rar/rar4-header.rar.b64"),
            include_str!("../scripts/fixtures/similarity-rar/rar5-data.rar.b64"),
            include_str!("../scripts/fixtures/similarity-rar/rar5-header.rar.b64"),
            include_str!("../scripts/fixtures/similarity-rar/rar5-mixed.rar.b64"),
        ] {
            let bytes = STANDARD.decode(sample.trim()).unwrap();
            assert_eq!(protected(&bytes), Some(true));
            let mut corrupted = bytes.clone();
            let index = format(&bytes).unwrap().signature_bytes() as usize;
            corrupted[index] ^= 1;
            assert_ne!(
                protected(&corrupted),
                Some(true),
                "Invalid header CRC must not establish a cached password exclusion"
            );
            for end in 0..index + 7 {
                assert_ne!(protected(&bytes[..end]), Some(true));
            }
        }
        let plain = STANDARD
            .decode(include_str!("../scripts/fixtures/similarity-rar/rar5-plain.rar.b64").trim())
            .unwrap();
        assert_eq!(protected(&plain), Some(false));
    }

    #[test]
    fn rar4_large_members_use_high_size_bits_and_recovery_flag_is_not_encryption() {
        let mut header = vec![0; 41];
        header[2] = 0x74;
        header[3..5].copy_from_slice(&0x8100u16.to_le_bytes());
        header[5..7].copy_from_slice(&41u16.to_le_bytes());
        header[7..11].copy_from_slice(&123u32.to_le_bytes());
        header[26] = 1;
        header[32] = 2;
        header[40] = b'x';
        let crc = crc32(&header[2..]) as u16;
        header[..2].copy_from_slice(&crc.to_le_bytes());
        assert_eq!(
            Format::Rar4.block(&header, false),
            Some(Block {
                encrypted: false,
                data_bytes: (2 << 32) + 123,
                end: false
            })
        );
        let mut main = vec![0; 13];
        main[2] = 0x73;
        main[3] = 0x40;
        main[5] = 13;
        let crc = crc32(&main[2..]) as u16;
        main[..2].copy_from_slice(&crc.to_le_bytes());
        assert!(!Format::Rar4.block(&main, true).unwrap().encrypted);
    }

    #[test]
    fn checksums_and_varints_reject_corrupt_or_unbounded_headers() {
        assert_eq!(crc32(b"123456789"), 0xcbf43926);
        assert_eq!(vint(&[0xff; 10], &mut 0), None);
        assert_eq!(vint(&[0x80], &mut 0), None);
        assert_eq!(vint(&[0xff, 0x01], &mut 0), Some(255));
        assert!(format(b"Rar!\x1a\x07\x02\x00").is_none());
        assert!(Format::Rar5
            .header_bytes(&[0, 0, 0, 0, 0xff, 0xff, 0xff, 1])
            .is_none());
        assert!(Format::Rar4.block(&[0; 7], true).is_none());
    }
}
