//go:build linux || darwin || freebsd

package main

import "syscall"

func lockCheckpoint(file string) (func(), error) {
	fd, err := syscall.Open(file, syscall.O_CREAT|syscall.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = syscall.Close(fd)
		return nil, err
	}
	return func() { _ = syscall.Close(fd) }, nil
}
