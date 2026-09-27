import CoreGraphics

/// Where a window of the host is dragged from: protocol/seam-protocol.md, section 6, window.movesize
enum MoveEdge: String, Equatable {
    case move
    case left, right, top, bottom
    case topLeft = "top-left"
    case topRight = "top-right"
    case bottomLeft = "bottom-left"
    case bottomRight = "bottom-right"

    var movesLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var movesRight: Bool { self == .right || self == .topRight || self == .bottomRight }
    var movesTop: Bool { self == .top || self == .topLeft || self == .topRight }
    var movesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
}

/// A drag of a window of the host that goes on the Mac: the window follows the mouse at once,
/// and the host gets the move in one step when the button goes up
/// Pure: frames and points in points of the Mac, y up
struct LocalDrag: Equatable {
    /// The smallest side a border drag leaves: Windows keeps its own minimum and settles the size after the drop
    static let minimumSide: CGFloat = 40

    let id: UInt64
    let edge: MoveEdge
    /// The frame of the window and the mouse in screen coordinates when the drag went local
    let startFrame: CGRect
    let startPoint: CGPoint

    /// The frame of the window with the mouse at this point
    /// The caption moves the whole window; a border moves its own sides only, the opposite ones stay
    func frame(at point: CGPoint) -> CGRect {
        let dx = point.x - startPoint.x
        let dy = point.y - startPoint.y
        if edge == .move {
            return startFrame.offsetBy(dx: dx, dy: dy)
        }
        var minX = startFrame.minX
        var maxX = startFrame.maxX
        var minY = startFrame.minY
        var maxY = startFrame.maxY
        if edge.movesLeft {
            minX = min(minX + dx, maxX - Self.minimumSide)
        }
        if edge.movesRight {
            maxX = max(maxX + dx, minX + Self.minimumSide)
        }
        // The top of Windows is the top of the Mac: the larger y of a frame that counts up
        if edge.movesTop {
            maxY = max(maxY + dy, minY + Self.minimumSide)
        }
        if edge.movesBottom {
            minY = min(minY + dy, maxY - Self.minimumSide)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
