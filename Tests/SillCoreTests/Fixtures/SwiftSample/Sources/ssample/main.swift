// A sample to profile: a hot loop (Pricing.total) and a cache that only grows.
import Foundation

enum Pricing {
    @inline(never)
    static func total(_ seed: Int) -> Double {
        var total = 0.0
        for i in 0 ..< 20000 {
            total += Double(seed + i).squareRoot() * sin(Double(i))
        }
        return total
    }
}

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 30
let started = Date()
var cache: [(Int, String, Double)] = []
while Date().timeIntervalSince(started) < seconds {
    for i in 0 ..< 2000 {
        cache.append((i, "customer-\(i)", Pricing.total(i)))
    }
    Thread.sleep(forTimeInterval: 0.005)
}

print("cached \(cache.count)")
