//go:build windows

package main

import (
	"os"
	"syscall"
)

func lockCheckpoint(file string) (func(), error) {
	if info, err := os.Lstat(file); err == nil && !info.Mode().IsRegular() {
		return nil, os.ErrPermission
	} else if err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	name, err := syscall.UTF16PtrFromString(file)
	if err != nil {
		return nil, err
	}
	h, err := syscall.CreateFile(name, syscall.GENERIC_READ|syscall.GENERIC_WRITE, 0, nil, syscall.OPEN_ALWAYS, syscall.FILE_ATTRIBUTE_NORMAL|syscall.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		return nil, err
	}
	return func() { _ = syscall.CloseHandle(h) }, nil
}
