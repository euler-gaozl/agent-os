package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
)

func privateDirectory(output string) (string, error) {
	root, err := filepath.Abs(output)
	if err != nil {
		return "", err
	}
	if err = os.MkdirAll(root, 0700); err != nil {
		return "", err
	}
	real, err := filepath.EvalSymlinks(root)
	if err != nil || real != root {
		return "", errors.New("physical private output directory required")
	}
	info, err := os.Stat(root)
	if err != nil {
		return "", err
	}
	if runtime.GOOS != "windows" && info.Mode().Perm()&0077 != 0 {
		return "", errors.New("output directory must be private")
	}
	return root, nil
}
func readPrivate(file string) ([]byte, error) {
	info, err := os.Lstat(file)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > 256<<10 || (runtime.GOOS != "windows" && info.Mode().Perm()&0077 != 0) {
		return nil, errors.New("private regular bounded file required")
	}
	return os.ReadFile(file)
}
func writeExact(file string, value any) error {
	b, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	b = append(b, '\n')
	old, err := readPrivate(file)
	if err == nil {
		if !bytes.Equal(old, b) {
			return errors.New("existing private configuration differs; refusing overwrite")
		}
		return nil
	}
	if !os.IsNotExist(err) {
		return err
	}
	return replacePrivate(file, b)
}
func replacePrivate(file string, b []byte) error {
	f, err := os.CreateTemp(filepath.Dir(file), ".provision-pending-")
	if err != nil {
		return err
	}
	temp := f.Name()
	defer os.Remove(temp)
	if _, err = f.Write(b); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err = os.Rename(temp, file); err != nil {
		return err
	}
	if runtime.GOOS != "windows" {
		directory, err := os.Open(filepath.Dir(file))
		if err != nil {
			return err
		}
		defer directory.Close()
		return directory.Sync()
	}
	return nil
}
func saveCheckpoint(file string, state checkpoint, previous *string) error {
	old, err := readPrivate(file)
	if err != nil {
		return err
	}
	if hash(old) != *previous {
		return errors.New("checkpoint changed outside the locked operation")
	}
	b, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	b = append(b, '\n')
	if bytes.Equal(old, b) {
		return nil
	}
	if err = replacePrivate(file, b); err != nil {
		return err
	}
	*previous = hash(b)
	return nil
}
