import SwiftUI

/// Colors lifted from the web app (frontend/src/App.css) so the native app reads
/// as the same product.
enum Theme {
    static let safe = Color(red: 0x2B / 255, green: 0x93 / 255, blue: 0x48 / 255)      // #2b9348
    static let safeTint = Color(red: 0xEE / 255, green: 0xFA / 255, blue: 0xF1 / 255)  // #eefaf1
    static let safeInk = Color(red: 0x1B / 255, green: 0x5E / 255, blue: 0x2F / 255)   // #1b5e2f
    static let fast = Color(red: 0x8D / 255, green: 0x99 / 255, blue: 0xAE / 255)      // #8d99ae
    static let danger = Color(red: 0xD9 / 255, green: 0x04 / 255, blue: 0x29 / 255)    // #d90429
    static let fatal = Color(red: 0xB3 / 255, green: 0x12 / 255, blue: 0x1F / 255)     // #b3121f
    static let serious = Color(red: 0xE8 / 255, green: 0x5D / 255, blue: 0x04 / 255)   // #e85d04
    static let minor = Color(red: 0xF4 / 255, green: 0xA6 / 255, blue: 0x3B / 255)     // #f4a63b
    static let zone = Color(red: 0x7B / 255, green: 0x2F / 255, blue: 0xF2 / 255)      // #7b2ff2
    static let school = Color(red: 0x2D / 255, green: 0x6C / 255, blue: 0xDF / 255)    // #2d6cdf
    static let verdictBG = Color(red: 0xFF / 255, green: 0xF8 / 255, blue: 0xE6 / 255) // #fff8e6
}

enum Fmt {
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "—" }
        let m = Int((seconds / 60).rounded())
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m) min"
    }

    static func distance(_ meters: Double?) -> String {
        guard let meters, meters.isFinite else { return "—" }
        if meters >= 1000 { return String(format: "%.1f km", meters / 1000) }
        return "\(Int(meters.rounded())) m"
    }

    static func risk(_ value: Double) -> String {
        String(format: "%.0f", value)
    }
}
