import XCTest

@testable import VibeRDP

/// A window of the host dragged on the Mac: the caption moves it whole, a border moves its own sides
final class LocalDragTests: XCTestCase {
    private let frame = CGRect(x: 100, y: 200, width: 400, height: 300)
    private let start = CGPoint(x: 300, y: 480)

    private func drag(_ edge: MoveEdge) -> LocalDrag {
        LocalDrag(id: 1, edge: edge, startFrame: frame, startPoint: start)
    }

    func testCaptionMovesTheWholeWindow() {
        XCTAssertEqual(drag(.move).frame(at: CGPoint(x: 350, y: 430)), frame.offsetBy(dx: 50, dy: -50))
        XCTAssertEqual(drag(.move).frame(at: start), frame)
    }

    func testBordersMoveTheirOwnSides() {
        let point = CGPoint(x: 320, y: 510)
        XCTAssertEqual(drag(.right).frame(at: point), CGRect(x: 100, y: 200, width: 420, height: 300))
        XCTAssertEqual(drag(.left).frame(at: point), CGRect(x: 120, y: 200, width: 380, height: 300))
        // The top of Windows is the larger y of the Mac
        XCTAssertEqual(drag(.top).frame(at: point), CGRect(x: 100, y: 200, width: 400, height: 330))
        XCTAssertEqual(drag(.bottom).frame(at: point), CGRect(x: 100, y: 230, width: 400, height: 270))
    }

    func testCornersMoveTwoSides() {
        let point = CGPoint(x: 280, y: 460)
        XCTAssertEqual(drag(.topLeft).frame(at: point), CGRect(x: 80, y: 200, width: 420, height: 280))
        XCTAssertEqual(drag(.topRight).frame(at: point), CGRect(x: 100, y: 200, width: 380, height: 280))
        XCTAssertEqual(drag(.bottomLeft).frame(at: point), CGRect(x: 80, y: 180, width: 420, height: 320))
        XCTAssertEqual(drag(.bottomRight).frame(at: point), CGRect(x: 100, y: 180, width: 380, height: 320))
    }

    func testBorderStopsAtTheSmallestSide() {
        let far = CGPoint(x: start.x + 1000, y: start.y - 1000)
        let shrunk = drag(.left).frame(at: far)
        XCTAssertEqual(shrunk.width, LocalDrag.minimumSide)
        XCTAssertEqual(shrunk.maxX, frame.maxX)
        let flat = drag(.top).frame(at: far)
        XCTAssertEqual(flat.height, LocalDrag.minimumSide)
        XCTAssertEqual(flat.minY, frame.minY)
    }
}
