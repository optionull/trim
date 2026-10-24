func total(_ values: [Int]) -> Int {
    values.reduce(0, +)
}

print(total([1, 2, 3]))
