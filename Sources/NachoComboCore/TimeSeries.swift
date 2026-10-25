import Foundation

/// Fixed-capacity ring buffer of timestamped multi-channel samples (history for the charts).
/// Missing values are stored as NaN and ignored by every reduction.
public final class TimeSeries {
    public enum Reduction { case mean, max }

    public let channels: Int
    public let capacity: Int
    private var times: [Double]
    private var storage: [Float]
    private var head = 0
    public private(set) var count = 0

    public init(channels: Int, capacity: Int) {
        precondition(channels > 0 && capacity > 0)
        self.channels = channels
        self.capacity = capacity
        times = Array(repeating: 0, count: capacity)
        storage = Array(repeating: .nan, count: capacity * channels)
    }

    public var lastTime: Double? { count == 0 ? nil : times[(head - 1 + capacity) % capacity] }

    public func removeAll() { head = 0; count = 0 }

    public func append(time: Double, values: [Double?]) {
        // The wall clock moved backwards (manual change): old buckets would be misplaced.
        if let last = lastTime, time < last { removeAll() }
        let base = head * channels
        for c in 0..<channels {
            let value = c < values.count ? values[c] : nil
            storage[base + c] = value.map { Float($0) } ?? .nan
        }
        times[head] = time
        head = (head + 1) % capacity
        count = Swift.min(count + 1, capacity)
    }

    /// The last `n` values of a channel, oldest first.
    public func recent(_ n: Int, channel: Int) -> [Double?] {
        let k = Swift.min(n, count)
        var out: [Double?] = []
        out.reserveCapacity(k)
        for back in stride(from: k, to: 0, by: -1) {
            let index = (head - back + capacity) % capacity
            let v = storage[index * channels + channel]
            out.append(v.isNaN ? nil : Double(v))
        }
        return out
    }

    public func latest(channel: Int) -> Double? { recent(1, channel: channel).first ?? nil }

    /// Splits the last `span` seconds into `bucketCount` buckets aligned to multiples of the bucket width
    /// (so bars do not shift between redraws). Each bucket holds one value per channel, or nil when no
    /// sample fell into it (app off, machine asleep).
    public func buckets(span: Double, count bucketCount: Int, now: Double,
                        reduction: Reduction = .mean) -> [[Double]?] {
        guard bucketCount > 0, span > 0 else { return [] }
        let width = span / Double(bucketCount)
        let lastStart = (now / width).rounded(.down) * width
        let start = lastStart - Double(bucketCount - 1) * width
        var acc = [Double](repeating: 0, count: bucketCount * channels)
        var hits = [Int](repeating: 0, count: bucketCount * channels)
        var i = 0
        while i < count {
            let index = (head - 1 - i + capacity) % capacity
            i += 1
            let t = times[index]
            if t < start { break }
            let bucket = Int(((t - start) / width).rounded(.down))
            guard bucket >= 0, bucket < bucketCount else { continue }
            for c in 0..<channels {
                let v = storage[index * channels + c]
                if v.isNaN { continue }
                let slot = bucket * channels + c
                switch reduction {
                case .mean: acc[slot] += Double(v)
                case .max: acc[slot] = hits[slot] == 0 ? Double(v) : Swift.max(acc[slot], Double(v))
                }
                hits[slot] += 1
            }
        }
        return (0..<bucketCount).map { bucket -> [Double]? in
            let base = bucket * channels
            guard (0..<channels).contains(where: { hits[base + $0] > 0 }) else { return nil }
            return (0..<channels).map { c -> Double in
                let n = hits[base + c]
                if n == 0 { return 0 }
                return reduction == .mean ? acc[base + c] / Double(n) : acc[base + c]
            }
        }
    }

    /// Largest raw value of a channel at or after `since`.
    public func maximum(channel: Int, since: Double) -> Double? {
        var best: Double?
        var i = 0
        while i < count {
            let index = (head - 1 - i + capacity) % capacity
            i += 1
            if times[index] < since { break }
            let v = storage[index * channels + channel]
            if !v.isNaN { best = Swift.max(best ?? -Double.infinity, Double(v)) }
        }
        return best
    }
}
