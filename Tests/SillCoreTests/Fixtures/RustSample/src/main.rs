// A sample to profile: a hot loop (pricing::total) and a cache that only grows.
mod pricing {
    #[inline(never)]
    pub fn total(seed: u64) -> f64 {
        let mut total = 0.0;
        for i in 0..20_000u64 {
            total += ((seed + i) as f64).sqrt() * (i as f64).sin();
        }
        total
    }
}

fn main() {
    let seconds: u64 = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(30);
    let started = std::time::Instant::now();
    let mut cache: Vec<(u64, String, f64)> = Vec::new();
    while started.elapsed().as_secs() < seconds {
        for i in 0..2000u64 {
            cache.push((i, format!("customer-{i}"), pricing::total(i)));
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    println!("cached {}", cache.len());
}
