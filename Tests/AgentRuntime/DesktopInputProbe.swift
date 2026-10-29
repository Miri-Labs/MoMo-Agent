import AppKit
import Foundation

enum DesktopError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { value } else { nil } }
}

@main struct DesktopInputProbe {
    @MainActor static func main() throws {
        var events: [CGEvent] = []
        let driver = DesktopInputDriver(bounds: { CGRect(x: -100, y: 50, width: 1200, height: 800) }, post: { events.append($0) })
        try driver.perform(["kind": "click", "x": 0.5, "y": 0.25])
        assert(events.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseUp])
        assert(events.last!.location == CGPoint(x: 500, y: 250)); events.removeAll()
        try driver.perform(["kind": "mouse_down", "x": 0.1, "y": 0.2])
        try driver.perform(["kind": "mouse_move", "x": 0.4, "y": 0.5])
        assert(events.last!.type == .leftMouseDragged)
        driver.reset(); assert(events.last!.type == .leftMouseUp)
        let count = events.count; driver.reset(); assert(events.count == count); events.removeAll()
        try driver.perform(["kind": "double_click", "x": 1.0, "y": 1.0])
        assert(events.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        assert(events.last!.getIntegerValueField(.mouseEventClickState) == 2); events.removeAll()
        try driver.perform(["kind": "double_click", "x": 0.3, "y": 0.3, "click_count": 2])
        assert(events.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseUp])
        assert(events.last!.getIntegerValueField(.mouseEventClickState) == 2); events.removeAll()
        try driver.perform(["kind": "right_click", "x": 0.3, "y": 0.3])
        assert(events.suffix(2).map(\.type) == [.rightMouseDown, .rightMouseUp]); events.removeAll()
        try driver.perform(["kind": "scroll", "x": 0.2, "y": 0.3, "delta": 120, "delta_x": -40])
        assert(events.first!.type == .mouseMoved && events.last!.type == .scrollWheel)
        assert(events.last!.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 120)
        assert(events.last!.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == -40); events.removeAll()
        try driver.perform(["kind": "key", "key": "a", "modifiers": ["command", "shift"]])
        assert(events.map(\.type) == [.keyDown, .keyUp])
        assert(events.allSatisfy { $0.flags.contains([.maskCommand, .maskShift]) }); events.removeAll()
        try driver.perform(["kind": "key", "key": "command+c"])
        assert(events.last!.getIntegerValueField(.keyboardEventKeycode) == 8); events.removeAll()
        let text = String(repeating: "a", count: 127) + "😀中文"
        try driver.perform(["kind": "text", "text": text])
        var decoded = ""
        for event in events where event.type == .keyDown {
            var count = 0; var units = [UniChar](repeating: 0, count: 1024)
            event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &count, unicodeString: &units)
            decoded += String(decoding: units.prefix(count), as: UTF16.self)
        }
        assert(decoded == text); events.removeAll()
        for invalid: [String: Any] in [
            ["kind": "key", "key": ""], ["kind": "key", "key": "hyper+a"],
            ["kind": "click", "x": Double.nan, "y": 0.2],
            ["kind": "drag", "x": 0.1, "y": 0.2, "to_x": 2.0, "to_y": 0.5],
            ["kind": "scroll", "delta": 1001], ["kind": "key", "key": "a", "modifiers": ["unknown"]]
        ] {
            do { try driver.perform(invalid); fatalError("Invalid input accepted") } catch { assert(events.isEmpty) }
        }
        var order = DesktopInputOrder()
        var accepted = try order.accept(owner: "session-a", sequence: 10); assert(accepted)
        accepted = try order.accept(owner: "session-a", sequence: 12); assert(accepted)
        accepted = try order.accept(owner: "session-a", sequence: 11); assert(!accepted, "Late mouse-down after reset must be discarded")
        accepted = try order.accept(owner: "session-a", sequence: 12); assert(!accepted)
        accepted = try order.accept(owner: "session-b", sequence: 1); assert(accepted)
        assert(order.last(for: "session-a") == 0)
        print("PASS pointer coordinates, live drag/reset, click counts, targeted wheel, modifier release, Unicode boundary, validation and late-input fencing (no OS events posted)")
    }
}
