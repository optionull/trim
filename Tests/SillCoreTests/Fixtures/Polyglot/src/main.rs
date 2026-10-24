fn total(values: &[u64]) -> u64 {
    values.iter().sum()
}

fn main() {
    println!("{}", total(&[1, 2, 3]));
}
