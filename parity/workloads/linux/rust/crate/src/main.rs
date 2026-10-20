extern "C" {
    fn native_mul(a: i32, b: i32) -> i32;
}

fn sum(n: i32) -> i32 {
    (1..=n).sum()
}

fn main() {
    let product = unsafe { native_mul(6, 7) };
    println!("hello from rust sum={} native_mul={}", sum(4), product);
}

#[cfg(test)]
mod tests {
    #[test]
    fn sums() {
        assert_eq!(super::sum(4), 10);
    }

    #[test]
    fn multiplies_natively() {
        assert_eq!(unsafe { super::native_mul(6, 7) }, 42);
    }
}
