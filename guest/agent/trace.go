package main

// Watching what a command does inside the sandbox.
//
// Three things are collected, all inside the guest:
//
//   - Decoy secrets. Fake key and credential files are placed where real
//     ones usually live (~/.ssh/id_rsa and friends). Nothing legitimate has
//     a reason to open most of them, so an open is a strong signal.
//   - File opens and program starts, through fanotify on the sandbox
//     filesystem. Only decoy opens and program starts are reported; the rest
//     are counted.
//   - Processes still alive when the command has finished.
//
// The host treats all of this as the guest's own account: useful, but code
// running as root in the guest could interfere with it. The network log and
// the file diff are made on the host and do not have that weakness.

import (
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"unsafe"
)

const (
	fanCloexec        = 0x1
	fanNonblock       = 0x2
	fanUnlimitedQueue = 0x10
	fanMarkAdd        = 0x1
	fanMarkFilesystem = 0x100
	fanOpen           = 0x20
	fanOpenExec       = 0x1000
	fanQOverflow      = 0x4000
	atFdcwd           = -100

	maxTracePaths  = 50000
	maxReportItems = 2000
	maxCmdline     = 200
	maxLiveEvents  = 300
)

type traceEntry struct {
	Path  string   `json:"path"`
	Count int      `json:"count"`
	Exec  bool     `json:"exec,omitempty"`
	Decoy bool     `json:"decoy,omitempty"`
	By    []string `json:"by,omitempty"`
}

type traceResult struct {
	Entries       []traceEntry `json:"entries"`
	FilesOpened   int          `json:"files_opened"`
	LeftRunning   []string     `json:"left_running"`
	DecoysPlaced  []string     `json:"decoys_placed"`
	DecoysChanged []string     `json:"decoys_changed"`
	Incomplete    bool         `json:"incomplete,omitempty"`
}

type watcher struct {
	file       *os.File
	finished   chan struct{}
	mu         sync.Mutex
	seen       map[string]*traceEntry
	incomplete bool
	decoys     map[string]string // sandbox-relative path -> content
	madeDirs   []string
	live       *frameWriter // set when the host wants events as they happen
	liveID     int
	liveSent   int
}

var activeWatch *watcher

func fanotifyInit(flags, eventFlags uint) (int, error) {
	fd, _, errno := syscall.Syscall(syscall.SYS_FANOTIFY_INIT, uintptr(flags), uintptr(eventFlags), 0)
	if errno != 0 {
		return -1, errno
	}
	return int(fd), nil
}

func fanotifyMark(fd int, flags uint, mask uint64, path string) error {
	p, err := syscall.BytePtrFromString(path)
	if err != nil {
		return err
	}
	dirfd := atFdcwd
	_, _, errno := syscall.Syscall6(syscall.SYS_FANOTIFY_MARK, uintptr(fd), uintptr(flags),
		uintptr(mask), uintptr(dirfd), uintptr(unsafe.Pointer(p)), 0)
	if errno != 0 {
		return errno
	}
	return nil
}

// startWatch must run after the sandbox is mounted and before the command.
func startWatch(live bool, out *frameWriter, id int) (int, error) {
	if activeWatch != nil {
		return 0, errors.New("already watching")
	}
	w := &watcher{seen: map[string]*traceEntry{}, decoys: map[string]string{}, finished: make(chan struct{}), liveID: id}
	if live {
		w.live = out
	}
	w.placeDecoys()

	fd, err := fanotifyInit(fanCloexec|fanNonblock|fanUnlimitedQueue, uint(os.O_RDONLY|syscall.O_LARGEFILE|syscall.O_CLOEXEC))
	if err != nil {
		w.removeDecoys()
		return 0, errors.New("fanotify_init: " + err.Error())
	}
	if err := fanotifyMark(fd, fanMarkAdd|fanMarkFilesystem, fanOpen|fanOpenExec, sandboxDir); err != nil {
		syscall.Close(fd)
		w.removeDecoys()
		return 0, errors.New("fanotify_mark: " + err.Error())
	}
	w.file = os.NewFile(uintptr(fd), "fanotify")
	go w.loop()
	activeWatch = w
	return len(w.decoys), nil
}

func (w *watcher) placeDecoys() {
	home := filepath.Join(sandboxDir, "root")
	for rel, content := range makeDecoys() {
		full := filepath.Join(home, rel)
		if _, err := os.Lstat(full); err == nil {
			continue // the sandbox has its own file here; leave it alone
		}
		// Remember which directories are ours, deepest last, to remove later.
		dir := filepath.Dir(full)
		var missing []string
		for d := dir; d != home && d != "/"; d = filepath.Dir(d) {
			if _, err := os.Lstat(d); err == nil {
				break
			}
			missing = append([]string{d}, missing...)
		}
		if err := os.MkdirAll(dir, 0o700); err != nil {
			continue
		}
		if err := os.WriteFile(full, []byte(content), 0o600); err != nil {
			continue
		}
		w.madeDirs = append(w.madeDirs, missing...)
		w.decoys[filepath.Join("root", rel)] = content
	}
}

// removeDecoys takes the decoys back out so they never reach saved state.
// It returns the ones the command altered or deleted.
func (w *watcher) removeDecoys() []string {
	var changed []string
	for rel, content := range w.decoys {
		full := filepath.Join(sandboxDir, rel)
		now, err := os.ReadFile(full)
		if err != nil || string(now) != content {
			changed = append(changed, rel)
		}
		_ = os.Remove(full)
	}
	// Deepest first; Remove only succeeds on directories left empty.
	sort.Slice(w.madeDirs, func(i, j int) bool { return len(w.madeDirs[i]) > len(w.madeDirs[j]) })
	for _, d := range w.madeDirs {
		_ = os.Remove(d)
	}
	sort.Strings(changed)
	return changed
}

func commandLine(pid int32) string {
	raw, err := os.ReadFile("/proc/" + strconv.Itoa(int(pid)) + "/cmdline")
	if err != nil || len(raw) == 0 {
		return "(exited)"
	}
	text := strings.TrimSpace(strings.ReplaceAll(string(raw), "\x00", " "))
	if len(text) > maxCmdline {
		text = text[:maxCmdline]
	}
	return text
}

func (w *watcher) loop() {
	defer close(w.finished)
	self := int32(os.Getpid())
	buf := make([]byte, 64*1024)
	for {
		n, err := w.file.Read(buf)
		if err != nil {
			return
		}
		for off := 0; off+24 <= n; {
			eventLen := int(binary.LittleEndian.Uint32(buf[off:]))
			if eventLen < 24 || off+eventLen > n {
				break
			}
			mask := binary.LittleEndian.Uint64(buf[off+8:])
			fd := int32(binary.LittleEndian.Uint32(buf[off+16:]))
			pid := int32(binary.LittleEndian.Uint32(buf[off+20:]))
			off += eventLen

			if mask&fanQOverflow != 0 {
				w.mu.Lock()
				w.incomplete = true
				w.mu.Unlock()
			}
			if fd < 0 {
				continue
			}
			path, err := os.Readlink("/proc/self/fd/" + strconv.Itoa(int(fd)))
			syscall.Close(int(fd))
			if err != nil || pid == self || !strings.HasPrefix(path, sandboxDir+"/") {
				continue
			}
			w.record(strings.TrimPrefix(path, sandboxDir+"/"), mask&fanOpenExec != 0, pid)
		}
	}
}

func (w *watcher) record(rel string, isExec bool, pid int32) {
	w.mu.Lock()
	defer w.mu.Unlock()
	entry := w.seen[rel]
	isNew := entry == nil
	if isNew {
		if len(w.seen) >= maxTracePaths {
			w.incomplete = true
			return
		}
		_, decoy := w.decoys[rel]
		entry = &traceEntry{Path: rel, Decoy: decoy}
		w.seen[rel] = entry
	}
	wasExec := entry.Exec
	entry.Count++
	entry.Exec = entry.Exec || isExec

	// Tell the host right away about the first decoy open and the first
	// start of each program. Capped, so a busy build cannot flood the line.
	if w.live != nil && w.liveSent < maxLiveEvents && ((isNew && entry.Decoy) || (isExec && !wasExec)) {
		w.liveSent++
		what := "exec"
		if entry.Decoy {
			what = "open"
		}
		w.live.send(event{ID: w.liveID, Event: "seen", What: what, Path: rel, By: commandLine(pid)})
	}
	// Who did it matters for decoys and program starts only.
	if (entry.Decoy || isExec) && len(entry.By) < 4 {
		who := commandLine(pid)
		for _, known := range entry.By {
			if known == who {
				return
			}
		}
		entry.By = append(entry.By, who)
	}
}

func leftRunning() []string {
	self := os.Getpid()
	dirs, _ := os.ReadDir("/proc")
	var out []string
	for _, d := range dirs {
		pid, err := strconv.Atoi(d.Name())
		if err != nil || pid == 1 || pid == self {
			continue
		}
		// Kernel threads have no command line.
		if cmd := commandLine(int32(pid)); cmd != "(exited)" {
			out = append(out, cmd)
		}
	}
	sort.Strings(out)
	return out
}

// stopWatch ends the trace and returns what was seen.
func stopWatch() (traceResult, error) {
	w := activeWatch
	if w == nil {
		return traceResult{}, errors.New("not watching")
	}
	activeWatch = nil
	running := leftRunning()
	if running == nil {
		running = []string{} // encode as [], not null
	}
	_ = w.file.Close()
	<-w.finished

	w.mu.Lock()
	defer w.mu.Unlock()
	result := traceResult{
		Entries: []traceEntry{}, LeftRunning: running, DecoysPlaced: []string{},
		FilesOpened: len(w.seen), Incomplete: w.incomplete,
	}
	for rel := range w.decoys {
		result.DecoysPlaced = append(result.DecoysPlaced, rel)
	}
	sort.Strings(result.DecoysPlaced)
	for _, e := range w.seen {
		if e.Decoy || e.Exec {
			result.Entries = append(result.Entries, *e)
		}
	}
	// Decoys first, then by path, so a cap never drops a decoy hit.
	sort.Slice(result.Entries, func(i, j int) bool {
		a, b := result.Entries[i], result.Entries[j]
		if a.Decoy != b.Decoy {
			return a.Decoy
		}
		return a.Path < b.Path
	})
	if len(result.Entries) > maxReportItems {
		result.Entries = result.Entries[:maxReportItems]
		result.Incomplete = true
	}
	if len(result.LeftRunning) > 200 {
		result.LeftRunning = result.LeftRunning[:200]
		result.Incomplete = true
	}
	result.DecoysChanged = w.removeDecoys()
	if result.DecoysChanged == nil {
		result.DecoysChanged = []string{}
	}
	return result, nil
}
