/// A symbolic physical key in the PC XT set-1 keyboard model used by SPICE.
///
/// This is not a Unicode or IME text API. The raw value is the scan-code form
/// accepted by ``SpiceClientInput/keyDown(scanCode:)`` and
/// ``SpiceClientInput/keyUp(scanCode:)``. Extended E0 keys use bit 8, matching
/// spice-gtk's public convention.
public enum SpicePhysicalKey: UInt32, CaseIterable, Sendable, Hashable {
    case escape = 0x01
    case digit1 = 0x02
    case digit2 = 0x03
    case digit3 = 0x04
    case digit4 = 0x05
    case digit5 = 0x06
    case digit6 = 0x07
    case digit7 = 0x08
    case digit8 = 0x09
    case digit9 = 0x0a
    case digit0 = 0x0b
    case minus = 0x0c
    case equal = 0x0d
    case deleteBackward = 0x0e
    case tab = 0x0f
    case q = 0x10
    case w = 0x11
    case e = 0x12
    case r = 0x13
    case t = 0x14
    case y = 0x15
    case u = 0x16
    case i = 0x17
    case o = 0x18
    case p = 0x19
    case leftBracket = 0x1a
    case rightBracket = 0x1b
    case enter = 0x1c
    case leftControl = 0x1d
    case a = 0x1e
    case s = 0x1f
    case d = 0x20
    case f = 0x21
    case g = 0x22
    case h = 0x23
    case j = 0x24
    case k = 0x25
    case l = 0x26
    case semicolon = 0x27
    case quote = 0x28
    case grave = 0x29
    case leftShift = 0x2a
    case backslash = 0x2b
    case z = 0x2c
    case x = 0x2d
    case c = 0x2e
    case v = 0x2f
    case b = 0x30
    case n = 0x31
    case m = 0x32
    case comma = 0x33
    case period = 0x34
    case slash = 0x35
    case rightShift = 0x36
    case keypadMultiply = 0x37
    case leftAlt = 0x38
    case space = 0x39
    case capsLock = 0x3a
    case f1 = 0x3b
    case f2 = 0x3c
    case f3 = 0x3d
    case f4 = 0x3e
    case f5 = 0x3f
    case f6 = 0x40
    case f7 = 0x41
    case f8 = 0x42
    case f9 = 0x43
    case f10 = 0x44
    case numLock = 0x45
    case scrollLock = 0x46
    case keypad7 = 0x47
    case keypad8 = 0x48
    case keypad9 = 0x49
    case keypadMinus = 0x4a
    case keypad4 = 0x4b
    case keypad5 = 0x4c
    case keypad6 = 0x4d
    case keypadPlus = 0x4e
    case keypad1 = 0x4f
    case keypad2 = 0x50
    case keypad3 = 0x51
    case keypad0 = 0x52
    case keypadDecimal = 0x53
    case f11 = 0x57
    case f12 = 0x58
    case keypadEqual = 0x59
    case f13 = 0x64
    case f14 = 0x65
    case f15 = 0x66
    case f16 = 0x67
    case f17 = 0x68
    case f18 = 0x69
    case f19 = 0x6a
    case f20 = 0x6b

    case keypadEnter = 0x11c
    case rightControl = 0x11d
    case keypadDivide = 0x135
    case rightAlt = 0x138
    case home = 0x147
    case arrowUp = 0x148
    case pageUp = 0x149
    case arrowLeft = 0x14b
    case arrowRight = 0x14d
    case end = 0x14f
    case arrowDown = 0x150
    case pageDown = 0x151
    case insert = 0x152
    case deleteForward = 0x153
    case leftMeta = 0x15b
    case rightMeta = 0x15c
    case contextMenu = 0x15d

    public var scanCode: UInt32 { rawValue }
}

/// Shared authority for symbolic SPICE keys and macOS hardware key codes.
///
/// AppKit views, application commands, and remote-control callers should use
/// this table instead of maintaining their own scan-code literals. Unknown
/// macOS keys remain unsupported rather than being guessed from characters.
public enum SpiceKeyMap {
    public static func scanCode(for key: SpicePhysicalKey) -> UInt32 {
        key.scanCode
    }

    public static func physicalKey(
        forMacVirtualKeyCode keyCode: UInt16
    ) -> SpicePhysicalKey? {
        macVirtualKeyMap[keyCode]
    }

    public static func scanCode(
        forMacVirtualKeyCode keyCode: UInt16
    ) -> UInt32? {
        physicalKey(forMacVirtualKeyCode: keyCode)?.scanCode
    }

    private static let macVirtualKeyMap: [UInt16: SpicePhysicalKey] = [
        0: .a, 1: .s, 2: .d, 3: .f, 4: .h, 5: .g,
        6: .z, 7: .x, 8: .c, 9: .v, 11: .b, 12: .q,
        13: .w, 14: .e, 15: .r, 16: .y, 17: .t, 18: .digit1,
        19: .digit2, 20: .digit3, 21: .digit4, 22: .digit6, 23: .digit5,
        24: .equal, 25: .digit9, 26: .digit7, 27: .minus, 28: .digit8,
        29: .digit0, 30: .rightBracket, 31: .o, 32: .u, 33: .leftBracket,
        34: .i, 35: .p, 36: .enter, 37: .l, 38: .j, 39: .quote,
        40: .k, 41: .semicolon, 42: .backslash, 43: .comma, 44: .slash,
        45: .n, 46: .m, 47: .period, 48: .tab, 49: .space, 50: .grave,
        51: .deleteBackward, 53: .escape, 54: .rightMeta, 55: .leftMeta,
        56: .leftShift, 57: .capsLock, 58: .leftAlt, 59: .leftControl,
        60: .rightShift, 61: .rightAlt, 62: .rightControl, 64: .f17,
        65: .keypadDecimal, 67: .keypadMultiply, 69: .keypadPlus,
        71: .numLock, 75: .keypadDivide, 76: .keypadEnter, 78: .keypadMinus,
        79: .f18, 80: .f19, 81: .keypadEqual, 82: .keypad0, 83: .keypad1,
        84: .keypad2, 85: .keypad3, 86: .keypad4, 87: .keypad5,
        88: .keypad6, 89: .keypad7, 90: .f20, 91: .keypad8, 92: .keypad9,
        96: .f5, 97: .f6, 98: .f7, 99: .f3, 100: .f8, 101: .f9,
        103: .f11, 105: .f13, 106: .f16, 107: .f14, 109: .f10,
        111: .f12, 113: .f15, 114: .insert, 115: .home, 116: .pageUp,
        117: .deleteForward, 118: .f4, 119: .end, 120: .f2, 121: .pageDown,
        122: .f1, 123: .arrowLeft, 124: .arrowRight, 125: .arrowDown,
        126: .arrowUp,
    ]
}
