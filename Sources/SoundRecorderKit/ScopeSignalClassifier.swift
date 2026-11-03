import Foundation

/// Selects a useful scope projection from recent audible channel samples.
public struct ScopeSignalClassifier {
    public private(set) var isNearMono = false
    private var candidateFrames = 0
    private let settleFrames = 12

    public init() {}

    /// Compare side energy with total channel energy. Silence leaves the current mode
    /// unchanged, and hysteresis avoids rapid switching near the threshold.
    public mutating func update(left: [Float], right: [Float]) -> Bool {
        let count = min(left.count, right.count)
        guard count > 0 else { return isNearMono }
        var energy = 0.0
        var difference = 0.0
        for i in 0..<count {
            let l = Double(left[i]), r = Double(right[i])
            energy += l * l + r * r
            let delta = l - r
            difference += delta * delta
        }
        guard energy / Double(count) > 0.00000008 else {
            candidateFrames = 0
            return isNearMono
        }
        let ratio = (difference / energy).squareRoot()
        let candidate = isNearMono ? ratio < 0.08 : ratio < 0.04
        if candidate == isNearMono {
            candidateFrames = 0
        } else {
            candidateFrames += 1
            if candidateFrames >= settleFrames {
                isNearMono = candidate
                candidateFrames = 0
            }
        }
        return isNearMono
    }
}
