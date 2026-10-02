package main

// 瀏覽器 KeyboardEvent.code → Windows 虛擬鍵碼;ext = 需要 KEYEVENTF_EXTENDEDKEY
type vkey struct {
	code uint16
	ext  bool
}

var keyMap = map[string]vkey{
	"Enter": {0x0D, false}, "Escape": {0x1B, false}, "Backspace": {0x08, false}, "Tab": {0x09, false}, "Space": {0x20, false},
	"Minus": {0xBD, false}, "Equal": {0xBB, false}, "BracketLeft": {0xDB, false}, "BracketRight": {0xDD, false},
	"Backslash": {0xDC, false}, "Semicolon": {0xBA, false}, "Quote": {0xDE, false}, "Backquote": {0xC0, false},
	"Comma": {0xBC, false}, "Period": {0xBE, false}, "Slash": {0xBF, false}, "IntlBackslash": {0xE2, false},
	"CapsLock": {0x14, false}, "PrintScreen": {0x2C, true}, "ScrollLock": {0x91, false}, "Pause": {0x13, false},
	"Insert": {0x2D, true}, "Home": {0x24, true}, "PageUp": {0x21, true}, "Delete": {0x2E, true}, "End": {0x23, true},
	"PageDown": {0x22, true}, "ArrowRight": {0x27, true}, "ArrowLeft": {0x25, true}, "ArrowDown": {0x28, true}, "ArrowUp": {0x26, true},
	"NumLock": {0x90, true}, "NumpadDivide": {0x6F, true}, "NumpadMultiply": {0x6A, false}, "NumpadSubtract": {0x6D, false},
	"NumpadAdd": {0x6B, false}, "NumpadEnter": {0x0D, true}, "NumpadDecimal": {0x6E, false}, "NumpadEqual": {0xBB, false},
	"ShiftLeft": {0xA0, false}, "ShiftRight": {0xA1, false}, "ControlLeft": {0xA2, false}, "ControlRight": {0xA3, true},
	"AltLeft": {0xA4, false}, "AltRight": {0xA5, true}, "MetaLeft": {0x5B, true}, "MetaRight": {0x5C, true}, "ContextMenu": {0x5D, true},
	"Help": {0x2F, false}, "Lang1": {0x15, false}, "Lang2": {0x19, false},
}

func init() {
	for c := 'A'; c <= 'Z'; c++ {
		keyMap["Key"+string(c)] = vkey{uint16(c), false}
	}
	for d := '0'; d <= '9'; d++ {
		keyMap["Digit"+string(d)] = vkey{uint16(d), false}
		keyMap["Numpad"+string(d)] = vkey{uint16(0x60 + (d - '0')), false}
	}
	for i := 1; i <= 24; i++ {
		keyMap["F"+itoa(i)] = vkey{uint16(0x70 + i - 1), false}
	}
}

var modifierCodes = map[string]bool{
	"ShiftLeft": true, "ShiftRight": true, "ControlLeft": true, "ControlRight": true,
	"AltLeft": true, "AltRight": true, "MetaLeft": true, "MetaRight": true, "CapsLock": true,
}
