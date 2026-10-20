fn twice(v: i32) -> i32 {
    v * 2
}

fn main() {
    let threads = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(0);
    println!(
        "hello from rust msvc bits={} twice={} threads={}",
        usize::BITS,
        twice(21),
        if threads > 0 { "ok" } else { "none" }
    );
}

#[cfg(test)]
mod tests {
    #[test]
    fn twice_doubles() {
        assert_eq!(super::twice(21), 42);
    }

    #[test]
    fn std_fs_works() {
        let p = std::env::temp_dir().join("parity_plain_test.txt");
        std::fs::write(&p, b"ok").unwrap();
        assert_eq!(std::fs::read(&p).unwrap(), b"ok");
        std::fs::remove_file(&p).unwrap();
    }
}
