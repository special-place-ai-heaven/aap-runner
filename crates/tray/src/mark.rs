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

/// One symbol per state, the same in the tray, the window header and the cards.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Sym {
    Off,
    NotInstalled,
    /// Supervisor down: status.json missing or stale.
    Down,
    Starting,
    Idle,
    Running,
    Draining,
    Paused,
    Error,
}

#[cfg(test)]
pub const SYMS: [Sym; 9] = [
    Sym::Off,
    Sym::NotInstalled,
    Sym::Down,
    Sym::Starting,
    Sym::Idle,
    Sym::Running,
    Sym::Draining,
    Sym::Paused,
    Sym::Error,
];

impl Sym {
    /// A hollow R means the system is not up.
    pub fn hollow(self) -> bool {
        matches!(self, Sym::Off | Sym::NotInstalled | Sym::Down)
    }

    pub fn label(self) -> &'static str {
        match self {
            Sym::Off => "Off",
            Sym::NotInstalled => "Not installed",
            Sym::Down => "Service not running",
            Sym::Starting => "Starting",
            Sym::Idle => "Idle",
            Sym::Running => "Running",
            Sym::Draining => "Draining",
            Sym::Paused => "Paused",
            Sym::Error => "Error",
        }
    }
}

/// At most this many busy bars.
pub const MAX_BUSY: usize = 3;

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
pub fn tray_rgba(size: u32, sym: Sym, busy: usize, system_uses_light_theme: bool) -> Vec<u8> {
    let [r, g, b] = ink(system_uses_light_theme);
    mask(size, sym, busy)
        .into_iter()
        .flat_map(|on| if on { [r, g, b, 0xff] } else { [0; 4] })
        .collect()
}

/// Inked pixels of the R (hollow or solid) plus the badge strip, row-major.
pub fn mask(size: u32, sym: Sym, busy: usize) -> Vec<bool> {
    let n = size as usize;
    let solid = glyph(size);
    let mut m = if sym.hollow() {
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
    } else {
        solid
    };
    for (o, s) in m.iter_mut().zip(strip(size, sym, busy)) {
        *o |= s;
    }
    m
}

/// The badge strip right of the R: the symbol on top, busy bars filled bottom-up.
fn strip(size: u32, sym: Sym, busy: usize) -> Vec<bool> {
    if size == 32 {
        let src = strip(16, sym, busy);
        return (0..32 * 32)
            .map(|i| src[(i / 32 / 2) * 16 + (i % 32) / 2])
            .collect();
    }
    let n = size as usize;
    // (first strip column, bar height, bottom row of each bar, bottom-up)
    let (x0, bar_h, bars): (usize, usize, [usize; 3]) = match size {
        16 => (12, 2, [15, 12, 9]),
        20 => (15, 2, [19, 16, 13]),
        24 => (18, 3, [23, 19, 15]),
        other => panic!("untuned tray size {other}"),
    };
    let mut m = vec![false; n * n];
    for (y, row) in symbol_rows(size, sym).iter().enumerate() {
        for (x, c) in row.bytes().enumerate() {
            m[y * n + x0 + x] = c == b'#';
        }
    }
    for &bottom in bars.iter().take(busy.min(MAX_BUSY)) {
        for y in bottom + 1 - bar_h..=bottom {
            for x in x0..n {
                m[y * n + x] = true;
            }
        }
    }
    m
}

/// Hand-tuned symbol bitmaps: 4 x 7 at 16 (from the design's sketches), 5 x 9 at 20, 6 x 11 at 24.
fn symbol_rows(size: u32, sym: Sym) -> &'static [&'static str] {
    match (size, sym) {
        (16, Sym::Off) => &["....", ".##.", "#..#", "#..#", ".##."],
        (16, Sym::NotInstalled) => &["....", "....", "####", "####"],
        (16, Sym::Down) => &[".##.", "#..#", "...#", "..#.", ".#..", "....", ".#.."],
        (16, Sym::Starting) => &[".##.", "....", ".##.", "....", ".##."],
        (16, Sym::Idle) => &["....", ".##.", "####", "####", ".##."],
        (16, Sym::Running) => &["#...", "##..", "###.", "####", "###.", "##..", "#..."],
        (16, Sym::Draining) => &["####", "#..#", ".##.", ".##.", "#..#", "####"],
        (16, Sym::Paused) => &["#..#"; 7],
        (16, Sym::Error) => &[".##.", ".##.", ".##.", ".##.", "....", ".##.", ".##."],
        (20, Sym::Off) => &[".....", ".###.", "#...#", "#...#", "#...#", ".###."],
        (20, Sym::NotInstalled) => &[".....", ".....", ".....", "#####", "#####"],
        (20, Sym::Down) => &[
            ".###.", "#...#", "....#", "...#.", "..#..", "..#..", ".....", "..#..", "..#..",
        ],
        (20, Sym::Starting) => &[
            ".###.", ".###.", ".....", ".###.", ".###.", ".....", ".###.", ".###.",
        ],
        (20, Sym::Idle) => &[".....", ".###.", "#####", "#####", "#####", ".###."],
        (20, Sym::Running) => &[
            "#....", "##...", "###..", "####.", "#####", "####.", "###..", "##...", "#....",
        ],
        (20, Sym::Draining) => &[
            "#####", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#####",
        ],
        (20, Sym::Paused) => &["##.##"; 9],
        (20, Sym::Error) => &[
            ".###.", ".###.", ".###.", ".###.", ".###.", ".....", ".###.", ".###.",
        ],
        (24, Sym::Off) => &[
            "......", ".####.", "##..##", "#....#", "#....#", "##..##", ".####.",
        ],
        (24, Sym::NotInstalled) => &["......", "......", "......", "######", "######"],
        (24, Sym::Down) => &[
            ".####.", "##..##", "....##", "...##.", "..##..", "..##..", "......", "..##..",
            "..##..",
        ],
        (24, Sym::Starting) => &[
            ".####.", ".####.", "......", "......", ".####.", ".####.", "......", "......",
            ".####.", ".####.",
        ],
        (24, Sym::Idle) => &[
            "......", ".####.", "######", "######", "######", "######", ".####.",
        ],
        (24, Sym::Running) => &[
            "#.....", "##....", "###...", "####..", "#####.", "######", "#####.", "####..",
            "###...", "##....", "#.....",
        ],
        (24, Sym::Draining) => &[
            "######", "#....#", ".#..#.", "..##..", "..##..", ".#..#.", "#....#", "######",
        ],
        (24, Sym::Paused) => &["##..##"; 11],
        (24, Sym::Error) => &[
            "..##..", "..##..", "..##..", "..##..", "..##..", "..##..", "......", "..##..",
            "..##..",
        ],
        (other, _) => panic!("untuned tray size {other}"),
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

    fn combos() -> impl Iterator<Item = (Sym, usize)> {
        SYMS.into_iter()
            .flat_map(|s| (0..=MAX_BUSY).map(move |b| (s, b)))
    }

    #[test]
    fn every_size_symbol_and_busy_count_renders_in_the_two_inks_only() {
        for size in TUNED_SIZES {
            for (sym, busy) in combos() {
                for (light, want) in [(false, INK_ON_DARK), (true, INK_ON_LIGHT)] {
                    let rgba = tray_rgba(size, sym, busy, light);
                    assert_eq!(rgba.len(), (size * size * 4) as usize);
                    let mut inked = 0;
                    for p in rgba.chunks(4) {
                        match p[3] {
                            0 => assert_eq!(&p[..3], &[0, 0, 0]),
                            0xff => {
                                inked += 1;
                                assert_eq!(&p[..3], &want, "{size} {sym:?} {busy}");
                            }
                            a => panic!("part-transparent pixel {a}"),
                        }
                    }
                    assert!(inked > 0 && inked < size * size, "{size} {sym:?} {busy}");
                }
            }
        }
    }

    #[test]
    fn every_pair_differs_and_the_strip_never_touches_the_r() {
        for size in TUNED_SIZES {
            let n = size as usize;
            let all: Vec<_> = combos().map(|(s, b)| ((s, b), mask(size, s, b))).collect();
            for i in 0..all.len() {
                for j in i + 1..all.len() {
                    assert_ne!(
                        all[i].1, all[j].1,
                        "{size}: {:?} == {:?}",
                        all[i].0, all[j].0
                    );
                }
            }
            let r = glyph(size);
            for ((sym, busy), _) in &all {
                let m = strip(size, *sym, *busy);
                assert!(m.iter().any(|p| *p), "{size} {sym:?} has a symbol");
                for i in (0..n * n).filter(|&i| m[i]) {
                    let (x, y) = ((i % n) as isize, (i / n) as isize);
                    for dy in -1..=1 {
                        for dx in -1..=1 {
                            let (nx, ny) = (x + dx, y + dy);
                            if (0..n as isize).contains(&nx) && (0..n as isize).contains(&ny) {
                                assert!(
                                    !r[ny as usize * n + nx as usize],
                                    "{size} {sym:?} {busy} touches the R"
                                );
                            }
                        }
                    }
                }
            }
            // Hollow is a strict subset of solid with a real hole.
            let hollow = mask(size, Sym::Off, 0);
            let off = strip(size, Sym::Off, 0);
            assert!(
                hollow
                    .iter()
                    .zip(&r)
                    .zip(&off)
                    .all(|((h, s), o)| !h || *s || *o)
            );
            let r_ink = |m: &[bool]| m.iter().zip(&off).filter(|(p, o)| **p && !**o).count();
            assert!(r_ink(&hollow) < r.iter().filter(|s| **s).count());
        }
    }

    #[test]
    fn hollow_only_when_not_up() {
        let down: Vec<_> = SYMS.into_iter().filter(|s| s.hollow()).collect();
        assert_eq!(down, [Sym::Off, Sym::NotInstalled, Sym::Down]);
    }

    #[test]
    fn symbol_bitmaps_fit_their_strip() {
        for (size, w, h) in [(16, 4, 7), (20, 5, 9), (24, 6, 11)] {
            for sym in SYMS {
                let rows = symbol_rows(size, sym);
                assert!(rows.len() <= h, "{size} {sym:?}");
                assert!(rows.iter().all(|r| r.len() == w), "{size} {sym:?}");
            }
        }
    }

    #[test]
    fn tuned_bitmaps_are_square() {
        for rows in [&R16[..], &R20[..], &R24[..]] {
            assert!(rows.iter().all(|r| r.len() == rows.len()));
        }
    }
}
