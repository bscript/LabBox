package main

// Sandbox state.
//
// The sandbox's whole filesystem lives in a tmpfs at /sandbox while the VM is
// up. The state disk (/dev/vda) holds it between runs as one tar archive
// written straight onto the block device. The host can read that archive
// with plain tar, and snapshots are just copies of the disk file.
//
// A run either saves the full tree at the end or, if the save fails or the
// VM is killed, the host throws the disk away and keeps the previous one.

import (
	"archive/tar"
	"bufio"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	sandboxDir = "/sandbox"
	stateDisk  = "/dev/vda"
)

var (
	stateMu     sync.Mutex
	activeRoot  string
	insideMount = []struct{ source, target, fstype, options string }{
		{"proc", "proc", "proc", ""},
		{"sysfs", "sys", "sysfs", ""},
		{"devtmpfs", "dev", "devtmpfs", ""},
		{"tmpfs", "tmp", "tmpfs", "mode=1777"},
		{"tmpfs", "run", "tmpfs", "mode=755"},
	}
)

func sandboxRoot() string {
	stateMu.Lock()
	defer stateMu.Unlock()
	return activeRoot
}

func resolveInRoot(root, name string) (string, error) {
	if strings.Contains(name, "/") {
		return name, nil
	}
	for _, dir := range filepath.SplitList(defaultPath) {
		candidate := filepath.Join(dir, name)
		if info, err := os.Lstat(filepath.Join(root, candidate)); err == nil && !info.IsDir() {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("exec: %q: executable file not found in sandbox PATH", name)
}

func waitForDisk() error {
	_ = exec.Command("/usr/sbin/modprobe", "virtio_blk").Run()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(stateDisk); err == nil {
			return nil
		}
		if time.Now().After(deadline) {
			return errors.New("no state disk attached")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func diskIsEmpty() (bool, error) {
	f, err := os.Open(stateDisk)
	if err != nil {
		return false, err
	}
	defer f.Close()
	block := make([]byte, 512)
	if _, err := io.ReadFull(f, block); err != nil {
		return false, err
	}
	for _, b := range block {
		if b != 0 {
			return false, nil
		}
	}
	return true, nil
}

func mountState() (created bool, err error) {
	stateMu.Lock()
	defer stateMu.Unlock()
	if activeRoot != "" {
		return false, errors.New("state already mounted")
	}
	if err := waitForDisk(); err != nil {
		return false, err
	}
	if err := os.MkdirAll(sandboxDir, 0o755); err != nil {
		return false, err
	}
	if err := syscall.Mount("tmpfs", sandboxDir, "tmpfs", 0, "size=75%,mode=755"); err != nil {
		return false, fmt.Errorf("mount sandbox tmpfs: %w", err)
	}

	empty, err := diskIsEmpty()
	if err != nil {
		return false, err
	}
	if empty {
		if err := populate(); err != nil {
			return false, fmt.Errorf("fill new sandbox: %w", err)
		}
	} else if err := loadState(); err != nil {
		return false, fmt.Errorf("load state: %w", err)
	}

	for _, d := range []string{"work", "root"} {
		_ = os.MkdirAll(filepath.Join(sandboxDir, d), 0o755)
	}
	for _, m := range insideMount {
		target := filepath.Join(sandboxDir, m.target)
		_ = os.MkdirAll(target, 0o755)
		if err := syscall.Mount(m.source, target, m.fstype, 0, m.options); err != nil {
			return false, fmt.Errorf("mount %s: %w", target, err)
		}
	}
	activeRoot = sandboxDir
	return empty, nil
}

// populate fills a brand-new sandbox with the ramdisk's userland.
func populate() error {
	out, err := exec.Command("/usr/bin/busybox", "cp", "-a", "/usr", "/etc", "/var", sandboxDir+"/").CombinedOutput()
	if err != nil {
		return fmt.Errorf("%v: %s", err, strings.TrimSpace(string(out)))
	}
	for link, target := range map[string]string{"bin": "usr/bin", "sbin": "usr/sbin", "lib": "usr/lib"} {
		if err := os.Symlink(target, filepath.Join(sandboxDir, link)); err != nil {
			return err
		}
	}

	// Make `apk add <package>` work as soon as the network gate allows
	// Alpine's CDN. Failing here only costs convenience, so it is logged.
	repos := "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main\nhttps://dl-cdn.alpinelinux.org/alpine/latest-stable/community\n"
	_ = os.MkdirAll(filepath.Join(sandboxDir, "etc/apk"), 0o755)
	if err := os.WriteFile(filepath.Join(sandboxDir, "etc/apk/repositories"), []byte(repos), 0o644); err != nil {
		logf("write apk repositories: %v", err)
	}
	if out, err := exec.Command("/usr/sbin/apk", "--root", sandboxDir, "--initdb", "--no-network", "add").CombinedOutput(); err != nil {
		logf("apk initdb: %v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// inSandbox maps an archive path to a path under /sandbox. Cleaning from "/"
// keeps a crafted name like "../../etc" inside the sandbox.
func inSandbox(name string) string {
	return filepath.Join(sandboxDir, filepath.Clean("/"+name))
}

func loadState() error {
	disk, err := os.Open(stateDisk)
	if err != nil {
		return err
	}
	defer disk.Close()
	archive := tar.NewReader(bufio.NewReaderSize(disk, 1<<20))

	for {
		hdr, err := archive.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		target := inSandbox(hdr.Name)
		mode := os.FileMode(hdr.Mode & 0o7777)

		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			f, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
			if err != nil {
				return err
			}
			if _, err := io.Copy(f, archive); err != nil {
				f.Close()
				return err
			}
			if err := f.Close(); err != nil {
				return err
			}
		case tar.TypeSymlink:
			if err := os.Symlink(hdr.Linkname, target); err != nil {
				return err
			}
		case tar.TypeLink:
			if err := os.Link(inSandbox(hdr.Linkname), target); err != nil {
				return err
			}
			continue
		case tar.TypeChar, tar.TypeBlock, tar.TypeFifo:
			kind := map[byte]uint32{tar.TypeChar: syscall.S_IFCHR, tar.TypeBlock: syscall.S_IFBLK, tar.TypeFifo: syscall.S_IFIFO}[hdr.Typeflag]
			dev := int(hdr.Devmajor<<8 | hdr.Devminor&0xff | (hdr.Devminor&^0xff)<<12)
			if err := syscall.Mknod(target, kind|uint32(mode), dev); err != nil {
				return err
			}
		default:
			continue
		}

		if err := os.Lchown(target, hdr.Uid, hdr.Gid); err != nil {
			return err
		}
		if hdr.Typeflag != tar.TypeSymlink {
			// After chown, which clears setuid bits.
			if err := syscall.Chmod(target, uint32(hdr.Mode&0o7777)); err != nil {
				return err
			}
			_ = os.Chtimes(target, hdr.ModTime, hdr.ModTime)
		}
	}
}

type countingWriter struct {
	w io.Writer
	n int64
}

func (c *countingWriter) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	c.n += int64(n)
	return n, err
}

// saveState writes the whole sandbox tree onto the state disk.
func saveState() (int64, error) {
	stateMu.Lock()
	defer stateMu.Unlock()
	if activeRoot == "" {
		return 0, errors.New("no state mounted")
	}
	syscall.Sync()

	var rootStat syscall.Stat_t
	if err := syscall.Lstat(sandboxDir, &rootStat); err != nil {
		return 0, err
	}
	disk, err := os.OpenFile(stateDisk, os.O_WRONLY, 0)
	if err != nil {
		return 0, err
	}
	defer disk.Close()
	counter := &countingWriter{w: disk}
	buffered := bufio.NewWriterSize(counter, 1<<20)
	archive := tar.NewWriter(buffered)

	type inode struct{ dev, ino uint64 }
	firstName := map[inode]string{}

	walkErr := filepath.WalkDir(sandboxDir, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if path == sandboxDir {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				return nil // deleted while we walked
			}
			return err
		}
		st, ok := info.Sys().(*syscall.Stat_t)
		if !ok {
			return fmt.Errorf("no stat for %s", path)
		}
		name := strings.TrimPrefix(path, sandboxDir+"/")

		// /proc, /sys, /dev, /tmp and /run are mounts. Keep the empty
		// directory, skip what is inside.
		mounted := info.IsDir() && uint64(st.Dev) != uint64(rootStat.Dev)
		if info.Mode()&fs.ModeSocket != 0 {
			return nil
		}

		link := ""
		if info.Mode()&fs.ModeSymlink != 0 {
			if link, err = os.Readlink(path); err != nil {
				return err
			}
		}
		hdr, err := tar.FileInfoHeader(info, link)
		if err != nil {
			return err
		}
		hdr.Name = name
		if info.IsDir() {
			hdr.Name += "/"
		}
		hdr.Uname, hdr.Gname = "", ""
		hdr.Format = tar.FormatPAX
		if mounted {
			hdr.Mode = 0o755
			hdr.Uid, hdr.Gid = 0, 0
		}

		regular := info.Mode().IsRegular()
		if regular && st.Nlink > 1 {
			key := inode{uint64(st.Dev), uint64(st.Ino)}
			if first, seen := firstName[key]; seen {
				hdr.Typeflag = tar.TypeLink
				hdr.Linkname = first
				hdr.Size = 0
				regular = false
			} else {
				firstName[key] = name
			}
		}

		if err := archive.WriteHeader(hdr); err != nil {
			return err
		}
		if regular {
			f, err := os.Open(path)
			if err != nil {
				return err
			}
			// Copy exactly the size in the header, even if the file changed.
			_, err = io.CopyN(archive, f, hdr.Size)
			f.Close()
			if err != nil {
				return fmt.Errorf("saving %s: %w", name, err)
			}
		}
		if mounted {
			return filepath.SkipDir
		}
		return nil
	})
	if walkErr != nil {
		return counter.n, walkErr
	}
	if err := archive.Close(); err != nil {
		return counter.n, err
	}
	if err := buffered.Flush(); err != nil {
		return counter.n, err
	}
	if err := disk.Sync(); err != nil {
		return counter.n, err
	}
	return counter.n, nil
}

// sandboxStats counts the sandbox's regular files and their total size,
// skipping the mounts inside it (/proc, /sys and so on).
func sandboxStats() (files, size int64) {
	var root syscall.Stat_t
	if syscall.Lstat(sandboxDir, &root) != nil {
		return 0, 0
	}
	_ = filepath.WalkDir(sandboxDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		if st, ok := info.Sys().(*syscall.Stat_t); ok && d.IsDir() && path != sandboxDir && uint64(st.Dev) != uint64(root.Dev) {
			return filepath.SkipDir
		}
		if info.Mode().IsRegular() {
			files++
			size += info.Size()
		}
		return nil
	})
	return files, size
}
