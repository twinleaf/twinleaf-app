// SPDX-License-Identifier: Apache-2.0

import Accelerate
import Foundation

/// Power spectral density of a captured record: the capture pane's FFT mode.
enum CaptureSpectrum {
    /// Fewer samples than this leave no usable bins.
    static let minimumSampleCount = 16

    /// One-sided PSD in `units²/Hz`: the whole record, mean removed and
    /// Hann-windowed, zero-padded to a power-of-two DFT so bins are spaced
    /// `sampleRate / dftSize` starting one spacing above DC. Scaled like the
    /// live Welch display (2 / (Σw² · fs)), so its square root is that
    /// display's ASD. DC and Nyquist are left out, as they are there.
    static func powerSpectralDensity(of values: [Double], sampleRate: Double) -> [PlotPoint] {
        let count = values.count
        guard count >= minimumSampleCount, sampleRate.isFinite, sampleRate > 0 else { return [] }

        let mean = values.reduce(0, +) / Double(count)
        let window = hannWindow(count: count)
        var dftSize = minimumSampleCount
        while dftSize < count {
            dftSize *= 2
        }

        var real = [Double](repeating: 0, count: dftSize)
        for index in 0..<count {
            real[index] = (values[index] - mean) * window[index]
        }
        let imaginary = [Double](repeating: 0, count: dftSize)
        guard let dft = try? vDSP.DiscreteFourierTransform(
            previous: nil,
            count: dftSize,
            direction: .forward,
            transformType: .complexComplex,
            ofType: Double.self
        ) else {
            return []
        }
        let output = dft.transform(real: real, imaginary: imaginary)

        let windowPower = window.reduce(0) { $0 + $1 * $1 }
        let scale = 2 / (windowPower * sampleRate)
        let binSpacing = sampleRate / Double(dftSize)
        var points: [PlotPoint] = []
        points.reserveCapacity(dftSize / 2)
        for bin in 1..<(dftSize / 2) {
            let re = output.real[bin]
            let im = output.imaginary[bin]
            let density = (re * re + im * im) * scale
            guard density.isFinite, density > 0 else { continue }
            points.append(PlotPoint(x: Double(bin) * binSpacing, y: density))
        }
        return points
    }

    /// Seconds per unit for the time units a capture's x axis uses. An empty
    /// unit is taken as seconds; anything else is nil, and the spectrum is
    /// then in cycles per that unit.
    static func secondsPerUnit(_ units: String) -> Double? {
        switch units.trimmingCharacters(in: .whitespaces) {
        case "", "s", "sec", "seconds": 1
        case "ms": 1e-3
        case "us", "µs", "μs": 1e-6
        case "ns": 1e-9
        case "min": 60
        default: nil
        }
    }

    /// Symmetric Hann, the same window the live Welch estimate applies.
    private static func hannWindow(count: Int) -> [Double] {
        (0..<count).map { index in
            let phase = Double.pi * Double(index) / Double(count - 1)
            return sin(phase) * sin(phase)
        }
    }
}
