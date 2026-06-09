// SPDX-License-Identifier: Apache-2.0

import Foundation

enum NumericDisplayPolicy {
    static let scientificDecimalDistance = 5
    static let defaultRPCFloatPrecisionPPM = 10.0
    static let rpcFloatPrecisionPPMRange = 0.001...1_000_000.0

    static var largeScientificThreshold: Double {
        pow(10, Double(scientificDecimalDistance))
    }

    static var smallScientificThreshold: Double {
        pow(10, -Double(scientificDecimalDistance))
    }

    static func usesScientificNotation(_ value: Double) -> Bool {
        let absoluteValue = abs(value)
        guard absoluteValue > 0 else { return false }
        return absoluteValue >= largeScientificThreshold
            || absoluteValue < smallScientificThreshold
    }

    static func fixed(_ value: Double, fractionDigits: Int) -> String {
        normalizedZero(value).formatted(
            .number
                .grouping(.automatic)
                .precision(.fractionLength(fractionDigits))
        )
    }

    static func significant(_ value: Double, maximumDigits: Int) -> String {
        normalizedZero(value).formatted(
            .number
                .grouping(.automatic)
                .precision(.significantDigits(1...maximumDigits))
        )
    }

    static func rpcFloat(_ value: Double, precisionPPM: Double) -> String {
        guard value.isFinite else { return String(describing: value) }

        let digits = significantDigits(forPrecisionPPM: precisionPPM)
        let formatted = String(format: "%.\(digits)g", normalizedZero(value))
        return formatted == "-0" ? "0" : formatted
    }

    static func clampedRPCFloatPrecisionPPM(_ value: Double) -> Double {
        min(max(value, rpcFloatPrecisionPPMRange.lowerBound), rpcFloatPrecisionPPMRange.upperBound)
    }

    private static func significantDigits(forPrecisionPPM precisionPPM: Double) -> Int {
        let ppm = clampedRPCFloatPrecisionPPM(precisionPPM)
        return min(max(Int(ceil(log10(10_000_000 / ppm))), 1), 17)
    }

    private static func normalizedZero(_ value: Double) -> Double {
        value == 0 ? 0 : value
    }
}
