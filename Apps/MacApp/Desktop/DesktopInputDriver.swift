import AppKit
import ApplicationServices

struct DesktopInputOrder {
    private var owner: String?
    private var sequence = 0
    func last(for owner: String) -> Int { self.owner == owner ? sequence : 0 }
    mutating func accept(owner: String, sequence value: Any?) throws -> Bool {
        if self.owner != owner { self.owner = owner; sequence = 0 }
        guard let value else { return true }
        guard let next = value as? Int, next > 0 else { throw DesktopError.message("输入顺序无效。") }
        guard next > sequence else { return false }
        sequence = next; return true
    }
}

/// Owns only injected input. The host validates paired identity and the current lease first.
@MainActor
final class DesktopInputDriver {
    private let post: (CGEvent) -> Void
    private let bounds: () -> CGRect
    private let source = CGEventSource(stateID: .privateState)
    private var held: CGMouseButton?
    private var position = CGPoint.zero

    init(bounds: @escaping () -> CGRect = { CGDisplayBounds(CGMainDisplayID()) },
         post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.bounds = bounds; self.post = post
    }

    func reset() {
        if let held, let event = CGEvent(mouseEventSource: source, mouseType: held == .right ? .rightMouseUp : .leftMouseUp,
                                         mouseCursorPosition: position, mouseButton: held) {
            event.flags = []; post(event)
        }
        held = nil
    }

    func perform(_ value: [String: Any]) throws {
        func point(_ xKey: String = "x", _ yKey: String = "y") throws -> CGPoint {
            guard let x = value[xKey] as? Double, let y = value[yKey] as? Double, x.isFinite, y.isFinite,
                  (0...1).contains(x), (0...1).contains(y) else { throw DesktopError.message("坐标超出屏幕范围。") }
            let rect = bounds()
            return CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        let modifiers = try Self.flags(value["modifiers"])
        func mouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left, count: Int64 = 1) throws {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
                throw DesktopError.message("鼠标事件不可用。")
            }
            event.flags = modifiers; event.setIntegerValueField(.mouseEventClickState, value: count)
            post(event); position = point
        }
        switch value["kind"] as? String {
        case "reset": reset()
        case "mouse_down":
            let target = try point()
            let buttonName = value["button"] as? String ?? "left"
            guard ["left", "right"].contains(buttonName), held == nil else { throw DesktopError.message("鼠标状态已变化，请重新接管。") }
            let button: CGMouseButton = buttonName == "right" ? .right : .left
            try mouse(.mouseMoved, at: target)
            try mouse(button == .right ? .rightMouseDown : .leftMouseDown, at: target, button: button)
            held = button
        case "mouse_move":
            let target = try point()
            try mouse(held == .right ? .rightMouseDragged : held == .left ? .leftMouseDragged : .mouseMoved,
                      at: target, button: held ?? .left)
        case "mouse_up":
            let target = try point()
            if let held { try mouse(held == .right ? .rightMouseUp : .leftMouseUp, at: target, button: held) }
            held = nil
        case "click", "double_click", "right_click":
            let target = try point(), button: CGMouseButton = value["kind"] as? String == "right_click" ? .right : .left
            guard held == nil else { throw DesktopError.message("请先结束拖动。") }
            if let count = value["click_count"] { guard let count = count as? Int, (1...2).contains(count) else { throw DesktopError.message("点击次数无效。") } }
            try mouse(.mouseMoved, at: target)
            let first = value["click_count"] as? Int == 2 ? 2 : 1
            let last = value["kind"] as? String == "double_click" ? 2 : first
            for count in first...last {
                try mouse(button == .right ? .rightMouseDown : .leftMouseDown, at: target, button: button, count: Int64(count))
                try mouse(button == .right ? .rightMouseUp : .leftMouseUp, at: target, button: button, count: Int64(count))
            }
        case "drag":
            // Legacy agent/phone clients submit a complete drag; new touch clients stream pointer phases.
            let start = try point(), end = try point("to_x", "to_y")
            guard held == nil else { throw DesktopError.message("请先结束拖动。") }
            try mouse(.mouseMoved, at: start); try mouse(.leftMouseDown, at: start)
            defer { reset() }; held = .left
            for n in 1...12 {
                let t = Double(n) / 12
                try mouse(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            }
        case "scroll":
            guard let delta = value["delta"] as? Int, (-1000...1000).contains(delta),
                  let horizontal = (value["delta_x"] ?? 0) as? Int, (-1000...1000).contains(horizontal) else {
                throw DesktopError.message("滚动参数无效。")
            }
            let target = value["x"] == nil && value["y"] == nil ? nil : try point()
            if let target { try mouse(.mouseMoved, at: target) }
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                      wheel1: Int32(delta), wheel2: Int32(horizontal), wheel3: 0) else { throw DesktopError.message("滚动事件不可用。") }
            event.flags = modifiers; post(event)
        case "text":
            guard let text = value["text"] as? String, !text.isEmpty, text.utf16.count <= 1024 else { throw DesktopError.message("文字过长，请分次输入。") }
            var chunk: [UniChar] = []
            func emit() throws {
                guard !chunk.isEmpty else { return }
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { throw DesktopError.message("键盘事件不可用。") }
                    event.flags = []
                    chunk.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress!) }
                    post(event)
                }
                chunk.removeAll(keepingCapacity: true)
            }
            // Keep composed characters together, including surrogate pairs at the old 128-unit boundary.
            for character in text {
                let units = Array(String(character).utf16)
                if chunk.count + units.count > 128 { try emit() }
                chunk.append(contentsOf: units)
            }
            try emit()
        case "key":
            guard let raw = value["key"] as? String else { throw DesktopError.message("按键无效。") }
            var names = raw.lowercased().split(separator: "+").map(String.init)
            guard let name = names.popLast() else { throw DesktopError.message("按键无效。") }
            let flags = try Self.flags(names).union(modifiers)
            guard let code = Self.codes[name] else { throw DesktopError.message("不支持这个按键。") }
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { throw DesktopError.message("键盘事件不可用。") }
                event.flags = flags; post(event)
            }
        default: throw DesktopError.message("不支持的输入方式。")
        }
    }

    private static func flags(_ value: Any?) throws -> CGEventFlags {
        guard let value else { return [] }
        guard let names = value as? [String], names.count <= 4 else { throw DesktopError.message("修饰键无效。") }
        let flags: [String: CGEventFlags] = ["command": .maskCommand, "shift": .maskShift, "option": .maskAlternate, "control": .maskControl]
        return try names.reduce(into: CGEventFlags()) { result, name in
            guard let flag = flags[name] else { throw DesktopError.message("修饰键无效。") }
            result.formUnion(flag)
        }
    }

    private static let codes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "'": 39, "k": 40,
        ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49,
        "`": 50, "backspace": 51, "escape": 53, "home": 115, "pageup": 116, "delete": 117, "end": 119,
        "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
    ]
}
