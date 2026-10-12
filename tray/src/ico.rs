//! The exe icon: the mark's R, white on a graphite tile (as Fathom's exe icon), encoded as a
//! Windows `.ico`. Only `examples/gen_ico.rs` and the test below use this; the exe itself
//! carries the committed `assets/aap-runner-tray.ico` through `build.rs`.

use crate::mark::{INK_ON_DARK, glyph};

/// Exe icon sizes, as Fathom's `.ico` carries them.
pub const ICO_SIZES: [u32; 6] = [16, 24, 32, 48, 64, 256];

const TILE: [u8; 3] = [0x1a, 0x1a, 0x1e];
const TILE_EDGE: [u8; 3] = [0x2d, 0x2d, 0x32];

/// White R on a graphite rounded tile, straight RGBA.
pub fn ico_rgba(n: u32) -> Vec<u8> {
    // (tuned R to draw, integer scale, tile margin)
    let (src, k, margin) = match n {
        16 => (16, 1, 0),
        24 => (24, 1, 0),
        32 => (24, 1, 2),
        48 => (16, 2, 3),
        64 => (24, 2, 4),
        256 => (16, 10, 16),
        other => panic!("no exe icon size {other}"),
    };
    let r_mask = glyph(src);
    let s = src as usize;
    // Bounding box of the R's ink.
    let inked = |x: usize, y: usize| r_mask[y * s + x];
    let xs: Vec<usize> = (0..s).filter(|&x| (0..s).any(|y| inked(x, y))).collect();
    let ys: Vec<usize> = (0..s).filter(|&y| (0..s).any(|x| inked(x, y))).collect();
    let (bx, by) = (xs[0], ys[0]);
    let (bw, bh) = (xs[xs.len() - 1] + 1 - bx, ys[ys.len() - 1] + 1 - by);
    let n = n as usize;
    let (ox, oy) = ((n - bw * k) / 2, (n - bh * k) / 2);

    let lo = margin as f32;
    let hi = (n - margin) as f32;
    let radius = ((n - 2 * margin) as f32 / 6.0).max(2.0);
    let edge = (n as f32 / 64.0).max(1.0);
    // Signed distance from a pixel centre to the rounded-rect boundary (negative inside).
    let dist = |px: f32, py: f32| {
        let dx = (lo + radius - px).max(px - (hi - radius)).max(0.0);
        let dy = (lo + radius - py).max(py - (hi - radius)).max(0.0);
        let corner = (dx * dx + dy * dy).sqrt() - radius;
        let side = (lo - px).max(px - hi).max(lo - py).max(py - hi);
        if dx > 0.0 && dy > 0.0 { corner } else { side }
    };

    let mut out = Vec::with_capacity(n * n * 4);
    for y in 0..n {
        for x in 0..n {
            let in_r = x >= ox
                && y >= oy
                && (x - ox) / k < bw
                && (y - oy) / k < bh
                && inked(bx + (x - ox) / k, by + (y - oy) / k);
            let d = dist(x as f32 + 0.5, y as f32 + 0.5);
            let alpha = (0.5 - d).clamp(0.0, 1.0);
            let rgb = if in_r {
                INK_ON_DARK
            } else if d > -edge {
                TILE_EDGE
            } else {
                TILE
            };
            out.extend_from_slice(&[rgb[0], rgb[1], rgb[2], (alpha * 255.0).round() as u8]);
        }
    }
    out
}

/// A Windows `.ico` with one 32-bit DIB entry per [`ICO_SIZES`] (alpha plus AND mask).
pub fn ico_bytes() -> Vec<u8> {
    let images: Vec<Vec<u8>> = ICO_SIZES.iter().map(|&n| dib(n, &ico_rgba(n))).collect();
    let count = ICO_SIZES.len() as u16;
    let mut out = Vec::new();
    out.extend_from_slice(&0u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&count.to_le_bytes());
    let mut offset = 6 + 16 * ICO_SIZES.len() as u32;
    for (&n, img) in ICO_SIZES.iter().zip(&images) {
        let side = if n >= 256 { 0 } else { n as u8 };
        out.extend_from_slice(&[side, side, 0, 0]);
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&32u16.to_le_bytes());
        out.extend_from_slice(&(img.len() as u32).to_le_bytes());
        out.extend_from_slice(&offset.to_le_bytes());
        offset += img.len() as u32;
    }
    for img in images {
        out.extend_from_slice(&img);
    }
    out
}

/// BITMAPINFOHEADER + bottom-up BGRA + bottom-up AND mask (1 = transparent).
fn dib(n: u32, rgba: &[u8]) -> Vec<u8> {
    let n = n as usize;
    let mask_row = n.div_ceil(32) * 4;
    let mut out = Vec::new();
    for v in [40u32, n as u32, 2 * n as u32] {
        out.extend_from_slice(&v.to_le_bytes());
    }
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&32u16.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(&((n * n * 4 + mask_row * n) as u32).to_le_bytes());
    out.extend_from_slice(&[0u8; 16]);
    for y in (0..n).rev() {
        for p in rgba[y * n * 4..(y + 1) * n * 4].chunks(4) {
            out.extend_from_slice(&[p[2], p[1], p[0], p[3]]);
        }
    }
    for y in (0..n).rev() {
        let mut row = vec![0u8; mask_row];
        for x in 0..n {
            if rgba[(y * n + x) * 4 + 3] == 0 {
                row[x / 8] |= 0x80 >> (x % 8);
            }
        }
        out.extend_from_slice(&row);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn committed_ico_matches_the_generator() {
        let committed: &[u8] = include_bytes!("../assets/aap-runner-tray.ico");
        assert!(
            committed == ico_bytes().as_slice(),
            "run: cargo run --example gen_ico"
        );
        assert_eq!(
            u16::from_le_bytes([committed[4], committed[5]]) as usize,
            ICO_SIZES.len()
        );
        for (i, &n) in ICO_SIZES.iter().enumerate() {
            let side = committed[6 + 16 * i];
            assert_eq!(if side == 0 { 256 } else { side as u32 }, n);
        }
    }
}
