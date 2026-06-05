import Foundation

/// PocketBase serializes dates as `"2006-01-02 15:04:05.000Z"`
/// these coders configure that format so dates round-trip with the server
/// and the delta-poll filter string matches exactly
public enum PocketBaseCoding {
    /// the canonical PocketBase datetime format
    public static let dateFormat = "yyyy-MM-dd HH:mm:ss.SSS'Z'"

    public static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = dateFormat
        return f
    }()

    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .formatted(dateFormatter)
        return e
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .formatted(dateFormatter)
        return d
    }

    /// format a date for use in a PocketBase list filter (e.g. `updated >= "…"`)
    public static func filterString(for date: Date) -> String {
        dateFormatter.string(from: date)
    }
}
