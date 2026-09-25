/// Turns the scroll deltas of macOS into the wheel units of Windows, 120 to a notch
/// Fractions of a unit wait for the next event, so a slow trackpad scroll still arrives
struct WheelAccumulator {
    /// A classic wheel reports lines, and one line is one notch
    static let unitsPerLine = 120.0
    /// Trackpads and the Magic Mouse report points: this is the speed of their scrolling, a setting with task 8.1
    static let unitsPerPoint = 2.0

    private var vertical = 0.0
    private var horizontal = 0.0

    /// macOS deltas are positive when the content moves down or right, the natural scrolling setting included
    /// Windows scrolls up for a positive vertical rotation and right for a positive horizontal one
    mutating func units(deltaX: Double, deltaY: Double, precise: Bool) -> (vertical: Int32, horizontal: Int32) {
        let scale = precise ? Self.unitsPerPoint : Self.unitsPerLine
        vertical += deltaY * scale
        horizontal -= deltaX * scale
        let whole = (vertical: vertical.rounded(.towardZero), horizontal: horizontal.rounded(.towardZero))
        vertical -= whole.vertical
        horizontal -= whole.horizontal
        return (Self.clamped(whole.vertical), Self.clamped(whole.horizontal))
    }

    private static func clamped(_ value: Double) -> Int32 {
        Int32(min(max(value, Double(Int32.min)), Double(Int32.max)))
    }
}
