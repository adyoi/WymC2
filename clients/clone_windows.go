//go:build windows

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
	cmd := exec.Command("cmd", "/C", command)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = dev, dev, dev
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP}
	return cmd.Start()
}
