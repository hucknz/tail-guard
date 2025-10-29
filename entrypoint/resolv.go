package main

import (
	"os"
	"path/filepath"
	"strings"
)

// setupLocalDNS ensures the common local nameserver lines are present at the top
// of /etc/resolv.conf. It prepends any missing lines (without duplicating existing
// entries), preserving the rest of the file. The write is done atomically.
//
// Desired lines (in order):
//   nameserver 127.0.0.1
//   nameserver ::1
//
// If /etc/resolv.conf does not exist, it will be created with these lines.
func setupLocalDNS() error {
	const path = "/etc/resolv.conf"
	desiredLines := []string{
		"nameserver 127.0.0.1",
		"nameserver ::1",
	}

	// Read existing file (if any)
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			// File missing — create it with desired lines and a trailing newline.
			content := strings.Join(desiredLines, "\n") + "\n"
			return os.WriteFile(path, []byte(content), 0644)
		}
		return err
	}

	orig := string(data)
	// Split preserving empty lines so we can prepend cleanly.
	lines := strings.Split(orig, "\n")

	// Build a set of existing trimmed lines for quick membership tests.
	exists := make(map[string]bool, len(lines))
	for _, ln := range lines {
		if t := strings.TrimSpace(ln); t != "" {
			exists[t] = true
		}
	}

	// Collect desired lines that are missing.
	var toPrepend []string
	for _, dl := range desiredLines {
		if !exists[dl] {
			toPrepend = append(toPrepend, dl)
		}
	}

	// Nothing to do.
	if len(toPrepend) == 0 {
		return nil
	}

	// Prepend missing lines to the original content.
	newLines := append(toPrepend, lines...)
	newContent := strings.Join(newLines, "\n")
	// Ensure trailing newline.
	if !strings.HasSuffix(newContent, "\n") {
		newContent += "\n"
	}

	// Write atomically: write to temp file in the same directory, then rename.
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, "resolv.conf.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()

	_, err = tmp.WriteString(newContent)
	if err != nil {
		tmp.Close()
		_ = os.Remove(tmpName)
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		_ = os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpName)
		return err
	}

	// Replace the file.
	if err := os.Rename(tmpName, path); err != nil {
		_ = os.Remove(tmpName)
		return err
	}

	return nil
}