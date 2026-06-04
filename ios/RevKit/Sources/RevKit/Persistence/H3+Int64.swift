import Foundation

/// H3 cell ids are 64-bit unsigned, but SQLite (and therefore SwiftData) stores `Int64`
/// these keep the bit-pattern round-trip in one place so `@Model` properties can hold `Int64`
/// while the game/render code keeps working in `UInt64`
extension Int64 {
    init(h3 cell: UInt64) { self = Int64(bitPattern: cell) }
    var h3Cell: UInt64 { UInt64(bitPattern: self) }
}

extension UInt64 {
    var int64Storage: Int64 { Int64(bitPattern: self) }
}
