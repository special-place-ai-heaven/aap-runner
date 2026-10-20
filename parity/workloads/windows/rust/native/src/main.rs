extern "C" {
    fn parity_add(a: i32, b: i32) -> i32;
    fn parity_cpu_count() -> u32;
}

fn add(a: i32, b: i32) -> i32 {
    unsafe { parity_add(a, b) }
}

fn main() {
    let cpus = unsafe { parity_cpu_count() };
    println!(
        "hello from rust native add={} cpus={}",
        add(2, 3),
        if cpus > 0 { "ok" } else { "none" }
    );
}

#[cfg(test)]
mod tests {
    #[test]
    fn native_add() {
        assert_eq!(super::add(2, 3), 5);
    }

    #[test]
    fn native_cpu_count() {
        assert!(unsafe { super::parity_cpu_count() } > 0);
    }
}
