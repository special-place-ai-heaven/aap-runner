//! The AAP Runner mark, drawn in code: a monochrome slab R, after Fathom's `mark.rs`.
//!
//! White ink on a dark taskbar, 0x1a1a1a on a light one. Hand-tuned bitmaps at 16, 20 and
//! 24 px; 32 is the 16 doubled (as Fathom's 32 is). The right-hand columns are kept clear of
//! the R so a small state overlay never touches it. The exe icon (`ico_bytes`) is the same R,
//! white on a graphite tile, drawn in `ico.rs`.

/// Ink on a dark taskbar.
pub const INK_ON_DARK: [u8; 3] = [0xff, 0xff, 0xff];

/// Ink on a light taskbar.
pub const INK_ON_LIGHT: [u8; 3] = [0x1a, 0x1a, 0x1a];

/// The sizes tuned by hand.
pub const TUNED_SIZES: [u32; 4] = [16, 20, 24, 32];

/// State overlay on the R. Each stays readable at 16 px.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Badge {
    /// Off / unknown / not installed: outlined R.
    Hollow,
    /// Starting / idle / draining: solid R.
    Solid,
    /// Solid R, dot bottom-right.
    Running,
    /// Solid R, short bar on the right.
    Paused,
    /// Solid R, dot top-right.
    Error,
}

#[cfg(test)]
pub const BADGES: [Badge; 5] = [
    Badge::Hollow,
    Badge::Solid,
    Badge::Running,
    Badge::Paused,
    Badge::Error,
];

pub fn ink(system_uses_light_theme: bool) -> [u8; 3] {
    if system_uses_light_theme {
        INK_ON_LIGHT
    } else {
        INK_ON_DARK
    }
}

/// The largest tuned drawing that fits `requested`, never below the smallest.
pub fn tuned_size(requested: u32) -> u32 {
    TUNED_SIZES
        .iter()
        .copied()
        .rfind(|s| *s <= requested)
        .unwrap_or(TUNED_SIZES[0])
}

/// 96 dpi asks for a 16 px small icon: 16 at 100 %, 20 at 125 %, 24 at 150 %, 32 at 200 %.
pub fn tuned_size_for_dpi(dpi: u32) -> u32 {
    tuned_size(16 * dpi.max(1) / 96)
}

/// Straight (not premultiplied) RGBA rows, transparent wherever there is no ink.
/// `size` must be one of [`TUNED_SIZES`].
pub fn tray_rgba(size: u32, badge: Badge, system_uses_light_theme: bool) -> Vec<u8> {
    let [r, g, b] = ink(system_uses_light_theme);
    mask(size, badge)
        .into_iter()
        .flat_map(|on| if on { [r, g, b, 0xff] } else { [0; 4] })
        .collect()
}

/// Inked pixels of the R plus its overlay, row-major.
pub fn mask(size: u32, badge: Badge) -> Vec<bool> {
    let n = size as usize;
    let solid = glyph(size);
    let mut m = match badge {
        Badge::Hollow => {
            // Keep only the edge: `t` px thick (2 at 32, like Fathom's outline).
            let t = (n / 16) as isize;
            let at = |x: isize, y: isize| {
                (0..n as isize).contains(&x)
                    && (0..n as isize).contains(&y)
                    && solid[y as usize * n + x as usize]
            };
            (0..n * n)
                .map(|i| {
                    let (x, y) = ((i % n) as isize, (i / n) as isize);
                    solid[i] && (-t..=t).any(|dy| (-t..=t).any(|dx| !at(x + dx, y + dy)))
                })
                .collect()
        }
        _ => solid,
    };
    let (d, w) = overlay_dims(size);
    let mut fill = |x0: usize, y0: usize, x1: usize, y1: usize| {
        for y in y0..y1 {
            for x in x0..x1 {
                m[y * n + x] = true;
            }
        }
    };
    match badge {
        Badge::Hollow | Badge::Solid => {}
        Badge::Running => fill(n - d, n - d, n, n),
        Badge::Error => fill(n - d, 0, n, d),
        Badge::Paused => fill(n - d, n * 5 / 16, n - d + w, n * 11 / 16),
    }
    m
}

/// (dot side, bar width) per size.
fn overlay_dims(size: u32) -> (usize, usize) {
    match size {
        16 => (3, 2),
        20 => (4, 3),
        24 => (5, 4),
        _ => (6, 4),
    }
}

/// The solid R at a tuned size.
pub fn glyph(size: u32) -> Vec<bool> {
    let parse = |rows: &[&str]| -> Vec<bool> {
        rows.iter()
            .flat_map(|r| r.bytes().map(|c| c == b'#'))
            .collect()
    };
    match size {
        16 => parse(&R16),
        20 => parse(&R20),
        24 => parse(&R24),
        32 => {
            let src = parse(&R16);
            (0..32 * 32)
                .map(|i| src[(i / 32 / 2) * 16 + (i % 32) / 2])
                .collect()
        }
        other => panic!("untuned tray size {other}"),
    }
}

const R16: [&str; 16] = [
    "................",
    ".########.......",
    ".#########......",
    ".##########.....",
    ".####...###.....",
    ".####...###.....",
    ".##########.....",
    ".#########......",
    ".########.......",
    ".####.###.......",
    ".####..###......",
    ".####..###......",
    ".####...###.....",
    ".####...###.....",
    ".####...###.....",
    "................",
];

const R20: [&str; 20] = [
    "....................",
    ".###########........",
    ".############.......",
    ".#############......",
    ".#####....####......",
    ".#####....####......",
    ".#####....####......",
    ".#####....####......",
    ".#############......",
    ".############.......",
    ".###########........",
    ".#####.####.........",
    ".#####.####.........",
    ".#####..####........",
    ".#####..####........",
    ".#####...####.......",
    ".#####...####.......",
    ".#####....####......",
    ".#####....####......",
    "....................",
];

const R24: [&str; 24] = [
    "........................",
    ".#############..........",
    ".##############.........",
    ".###############........",
    ".################.......",
    ".######.....#####.......",
    ".######.....#####.......",
    ".######.....#####.......",
    ".######.....#####.......",
    ".################.......",
    ".###############........",
    ".##############.........",
    ".#############..........",
    ".######.#####...........",
    ".######.#####...........",
    ".######..#####..........",
    ".######..#####..........",
    ".######...#####.........",
    ".######...#####.........",
    ".######....#####........",
    ".######....#####........",
    ".######.....#####.......",
    ".######.....#####.......",
    "........................",
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ink_follows_the_taskbar_theme() {
        assert_eq!(ink(false), [0xff, 0xff, 0xff]);
        assert_eq!(ink(true), [0x1a, 0x1a, 0x1a]);
    }

    #[test]
    fn size_follows_the_display_scale() {
        for (dpi, want) in [
            (96, 16),
            (120, 20),
            (144, 24),
            (192, 32),
            (168, 24),
            (240, 32),
            (72, 16),
            (0, 16),
        ] {
            assert_eq!(tuned_size_for_dpi(dpi), want, "{dpi} dpi");
        }
    }

    #[test]
    fn every_size_and_badge_renders_in_the_two_inks_only() {
        for size in TUNED_SIZES {
            for badge in BADGES {
                for (light, want) in [(false, INK_ON_DARK), (true, INK_ON_LIGHT)] {
                    let rgba = tray_rgba(size, badge, light);
                    assert_eq!(rgba.len(), (size * size * 4) as usize);
                    let mut inked = 0;
                    for p in rgba.chunks(4) {
                        match p[3] {
                            0 => assert_eq!(&p[..3], &[0, 0, 0]),
                            0xff => {
                                inked += 1;
                                assert_eq!(&p[..3], &want, "{size} {badge:?}");
                            }
                            a => panic!("part-transparent pixel {a}"),
                        }
                    }
                    assert!(inked > 0 && inked < size * size, "{size} {badge:?}");
                }
            }
        }
    }

    #[test]
    fn every_badge_differs_and_overlays_never_touch_the_r() {
        for size in TUNED_SIZES {
            let n = size as usize;
            let masks: Vec<_> = BADGES.iter().map(|&b| mask(size, b)).collect();
            for i in 0..masks.len() {
                for j in i + 1..masks.len() {
                    assert_ne!(
                        masks[i], masks[j],
                        "{size}: {:?} == {:?}",
                        BADGES[i], BADGES[j]
                    );
                }
            }
            let r = glyph(size);
            for badge in [Badge::Running, Badge::Paused, Badge::Error] {
                let m = mask(size, badge);
                for i in (0..n * n).filter(|&i| m[i] && !r[i]) {
                    let (x, y) = ((i % n) as isize, (i / n) as isize);
                    for (dx, dy) in [
                        (-1, 0),
                        (1, 0),
                        (0, -1),
                        (0, 1),
                        (-1, -1),
                        (-1, 1),
                        (1, -1),
                        (1, 1),
                    ] {
                        let (nx, ny) = (x + dx, y + dy);
                        if (0..n as isize).contains(&nx) && (0..n as isize).contains(&ny) {
                            assert!(
                                !r[ny as usize * n + nx as usize],
                                "{size} {badge:?} touches the R"
                            );
                        }
                    }
                }
            }
            // Hollow is a strict subset of solid with a real hole.
            let hollow = mask(size, Badge::Hollow);
            assert!(hollow.iter().zip(&r).all(|(h, s)| !h || *s));
            assert!(hollow.iter().filter(|h| **h).count() < r.iter().filter(|s| **s).count());
        }
    }

    #[test]
    fn tuned_bitmaps_are_square() {
        for rows in [&R16[..], &R20[..], &R24[..]] {
            assert!(rows.iter().all(|r| r.len() == rows.len()));
        }
    }
}
