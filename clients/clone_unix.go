//go:build !windows

package main

import (
	"os"
	"os/exec"
	"syscall"
)

func cloneRelaunch(command string) error {
	dev, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer dev.Close()
	cmd := exec.Command("sh", "-c", command)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = dev, dev, dev
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	return cmd.Start()
}
