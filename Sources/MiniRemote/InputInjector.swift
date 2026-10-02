import Foundation
import CoreGraphics

/// 把網頁端傳來的滑鼠/鍵盤事件,用 CGEvent 注入到這台 Mac(需要「輔助使用」權限)
final class InputInjector {
    /// 目前擷取的顯示器在全域座標中的位置(點)
    var displayFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    private let source = CGEventSource(stateID: .hidSystemState)
    private var leftDown = false
    private var rightDown = false
    private var otherDown = false
    private var pressedKeys = Set<CGKeyCode>()
    private var currentFlags: CGEventFlags = []
    private var lastPoint = CGPoint.zero

    private func point(_ nx: Double, _ ny: Double) -> CGPoint {
        let cx = min(max(nx, 0), 1), cy = min(max(ny, 0), 1)
        return CGPoint(x: displayFrame.minX + cx * displayFrame.width,
                       y: displayFrame.minY + cy * displayFrame.height)
    }

    func mouseMove(nx: Double, ny: Double) {
        let p = point(nx, ny)
        lastPoint = p
        let type: CGEventType
        let button: CGMouseButton
        if leftDown { type = .leftMouseDragged; button = .left }
        else if rightDown { type = .rightMouseDragged; button = .right }
        else if otherDown { type = .otherMouseDragged; button = .center }
        else { type = .mouseMoved; button = .left }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.flags = currentFlags
        e.post(tap: .cghidEventTap)
    }

    func mouseButton(button: Int, down: Bool, nx: Double, ny: Double, clicks: Int) {
        let p = point(nx, ny)
        lastPoint = p
        let type: CGEventType
        let btn: CGMouseButton
        switch button {
        case 2:
            type = down ? .rightMouseDown : .rightMouseUp; btn = .right; rightDown = down
        case 1:
            type = down ? .otherMouseDown : .otherMouseUp; btn = .center; otherDown = down
        default:
            type = down ? .leftMouseDown : .leftMouseUp; btn = .left; leftDown = down
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: btn) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, min(3, clicks))))
        e.flags = currentFlags
        e.post(tap: .cghidEventTap)
    }

    /// dx/dy 為瀏覽器 wheel 事件的像素量(往下捲為正)
    func scroll(dx: Double, dy: Double) {
        let y = Int32(max(-1000, min(1000, -dy.rounded())))
        let x = Int32(max(-1000, min(1000, -dx.rounded())))
        if x == 0 && y == 0 { return }
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0) else { return }
        e.flags = currentFlags
        e.post(tap: .cghidEventTap)
    }

    func key(code: String, key: String, down: Bool, mods: Int) {
        currentFlags = Self.flags(from: mods)
        if let vk = KeyMap.codes[code] {
            if KeyMap.modifierCodes.contains(code) {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: down) else { return }
                e.type = .flagsChanged
                e.flags = currentFlags
                e.post(tap: .cghidEventTap)
                return
            }
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: down) else { return }
            var flags = currentFlags
            if KeyMap.arrowCodes.contains(code) { flags.insert(.maskNumericPad); flags.insert(.maskSecondaryFn) }
            if code.hasPrefix("Numpad") { flags.insert(.maskNumericPad) }
            e.flags = flags
            e.post(tap: .cghidEventTap)
            if down { pressedKeys.insert(vk) } else { pressedKeys.remove(vk) }
            return
        }
        // 沒有對應鍵碼:如果是可列印字元(例如中文輸入法組好的字)就直接打字
        guard down else { return }
        if key.count == 1 || (key.count > 1 && key.unicodeScalars.allSatisfy { $0.value > 0x7F }) {
            typeString(key)
        }
    }

    /// 直接輸入一段文字(不經過鍵盤配置,中文也可以)
    func typeString(_ text: String) {
        // 每次最多送 20 個 UTF-16 單元,避免太長被截斷
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 20, units.count)])
            i += 20
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
            chunk.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buf.baseAddress)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buf.baseAddress)
            }
            down.flags = []
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// 網頁失焦或斷線時,把所有按住的東西放開,避免卡鍵
    func releaseAll() {
        for vk in pressedKeys {
            if let e = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: false) { e.post(tap: .cghidEventTap) }
        }
        pressedKeys.removeAll()
        for code in ["ShiftLeft", "ControlLeft", "AltLeft", "MetaLeft"] {
            if let vk = KeyMap.codes[code], let e = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: false) {
                e.type = .flagsChanged
                e.flags = []
                e.post(tap: .cghidEventTap)
            }
        }
        currentFlags = []
        if leftDown { releaseButton(.leftMouseUp, .left); leftDown = false }
        if rightDown { releaseButton(.rightMouseUp, .right); rightDown = false }
        if otherDown { releaseButton(.otherMouseUp, .center); otherDown = false }
    }

    private func releaseButton(_ type: CGEventType, _ btn: CGMouseButton) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: lastPoint, mouseButton: btn) else { return }
        e.post(tap: .cghidEventTap)
    }

    static func flags(from mods: Int) -> CGEventFlags {
        var f: CGEventFlags = []
        if mods & 1 != 0 { f.insert(.maskShift) }
        if mods & 2 != 0 { f.insert(.maskControl) }
        if mods & 4 != 0 { f.insert(.maskAlternate) }
        if mods & 8 != 0 { f.insert(.maskCommand) }
        if mods & 16 != 0 { f.insert(.maskAlphaShift) }
        return f
    }
}
