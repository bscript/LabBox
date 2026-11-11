// labbox-agent runs inside the sandbox VM.
//
// As PID 1 it sets up a minimal Linux userland, starts a copy of itself in
// serve mode, reaps orphans, and powers the VM off when the server exits.
//
// In serve mode it talks to the host over a virtio console port named
// "labbox.control". Frames are a 4-byte big-endian length followed by JSON.
// The host is trusted; everything this agent runs is not.
package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	protocolVersion = 5
	controlPortName = "labbox.control"
	maxFrame        = 1 << 20
	chunkSize       = 32 * 1024
	defaultPath     = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
)

type request struct {
	ID        int               `json:"id"`
	Op        string            `json:"op"`
	Argv      []string          `json:"argv,omitempty"`
	Env       map[string]string `json:"env,omitempty"`
	Cwd       string            `json:"cwd,omitempty"`
	TimeoutMs int               `json:"timeout_ms,omitempty"`
	Stdin     []byte            `json:"stdin,omitempty"`
	Watch     bool              `json:"watch,omitempty"`
	Live      bool              `json:"live,omitempty"`
}

type event struct {
	ID       int          `json:"id"`
	Event    string       `json:"event"`
	Data     []byte       `json:"data,omitempty"`
	Code     *int         `json:"code,omitempty"`
	TimedOut bool         `json:"timed_out,omitempty"`
	Error    string       `json:"error,omitempty"`
	Version  int          `json:"version,omitempty"`
	Created  bool         `json:"created,omitempty"`
	Bytes    int64        `json:"bytes,omitempty"`
	Trace    *traceResult `json:"trace,omitempty"`
	Kernel   string       `json:"kernel,omitempty"`
	Files    int64        `json:"files,omitempty"`
	Decoys   int          `json:"decoys,omitempty"`
	What     string       `json:"what,omitempty"`
	Path     string       `json:"path,omitempty"`
	By       string       `json:"by,omitempty"`
}

func logf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "labbox-agent: "+format+"\n", args...)
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--serve" {
		serve()
		return
	}
	if os.Getpid() != 1 {
		logf("run as init (rdinit=/labbox-agent) or with --serve")
		os.Exit(2)
	}
	runAsInit()
}

// ---- PID 1 ----

func runAsInit() {
	mounts := []struct{ source, target, fstype string }{
		{"proc", "/proc", "proc"},
		{"sysfs", "/sys", "sysfs"},
		{"devtmpfs", "/dev", "devtmpfs"},
		{"tmpfs", "/tmp", "tmpfs"},
		{"tmpfs", "/run", "tmpfs"},
	}
	for _, m := range mounts {
		_ = os.MkdirAll(m.target, 0o755)
		if err := syscall.Mount(m.source, m.target, m.fstype, 0, ""); err != nil && !errors.Is(err, syscall.EBUSY) {
			logf("mount %s: %v", m.target, err)
		}
	}
	_ = os.MkdirAll("/work", 0o755)
	_ = os.MkdirAll("/root", 0o700)
	_ = syscall.Sethostname([]byte(randomHostname()))
	_ = os.Setenv("PATH", defaultPath)

	// Alpine's ramdisk ships busybox without its command links.
	if err := exec.Command("/usr/bin/busybox", "--install", "-s").Run(); err != nil {
		logf("busybox --install: %v", err)
	}

	env := []string{"PATH=" + defaultPath, "HOME=/root", "TERM=dumb"}
	server, err := syscall.ForkExec("/proc/self/exe", []string{"labbox-agent", "--serve"},
		&syscall.ProcAttr{Dir: "/", Env: env, Files: []uintptr{0, 1, 2}})
	if err != nil {
		logf("cannot start server: %v", err)
		powerOff()
	}

	// Reap everything. Orphans from sandboxed commands land here.
	for {
		var status syscall.WaitStatus
		pid, err := syscall.Wait4(-1, &status, 0, nil)
		if errors.Is(err, syscall.EINTR) {
			continue
		}
		if err != nil || pid == server {
			break
		}
	}
	powerOff()
}

func powerOff() {
	syscall.Sync()
	_ = syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF)
	// If power-off is refused, do not exit: PID 1 exiting panics the kernel.
	select {}
}

// ---- server ----

type frameWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (f *frameWriter) send(e event) {
	body, err := json.Marshal(e)
	if err != nil || len(body) > maxFrame {
		logf("dropping unsendable event %q", e.Event)
		return
	}
	frame := make([]byte, 4+len(body))
	binary.BigEndian.PutUint32(frame, uint32(len(body)))
	copy(frame[4:], body)
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, err := f.w.Write(frame); err != nil {
		logf("write to host: %v", err)
	}
}

// readFull tolerates the zero-byte reads a virtio port gives while the host
// side is momentarily not connected.
func readFull(r io.Reader, buf []byte) error {
	for got := 0; got < len(buf); {
		n, err := r.Read(buf[got:])
		got += n
		if err != nil && !errors.Is(err, io.EOF) {
			return err
		}
		if n == 0 {
			time.Sleep(50 * time.Millisecond)
		}
	}
	return nil
}

func readRequest(r io.Reader) (request, error) {
	var req request
	head := make([]byte, 4)
	if err := readFull(r, head); err != nil {
		return req, err
	}
	size := binary.BigEndian.Uint32(head)
	if size == 0 || size > maxFrame {
		return req, fmt.Errorf("bad frame size %d", size)
	}
	body := make([]byte, size)
	if err := readFull(r, body); err != nil {
		return req, err
	}
	return req, json.Unmarshal(body, &req)
}

// findPort looks for a virtio port by name, retrying for up to wait.
func findPort(name string, wait time.Duration) (string, bool) {
	deadline := time.Now().Add(wait)
	for {
		names, _ := filepath.Glob("/sys/class/virtio-ports/*/name")
		for _, n := range names {
			raw, err := os.ReadFile(n)
			if err == nil && strings.TrimSpace(string(raw)) == name {
				return "/dev/" + filepath.Base(filepath.Dir(n)), true
			}
		}
		if !time.Now().Before(deadline) {
			return "", false
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func serve() {
	path, ok := findPort(controlPortName, 10*time.Second)
	if !ok {
		logf("no virtio port named %q", controlPortName)
		os.Exit(1)
	}
	// Ports of one device appear together, so the network port (if the host
	// attached one) is visible by now.
	startNet()
	port, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		logf("open %s: %v", path, err)
		os.Exit(1)
	}
	out := &frameWriter{w: port}
	out.send(event{Event: "ready", Version: protocolVersion, Kernel: kernelRelease()})

	for {
		req, err := readRequest(port)
		if err != nil {
			// The stream cannot be resynced after a bad frame. Stop, and let
			// PID 1 power the VM off.
			logf("read from host: %v", err)
			os.Exit(1)
		}
		switch req.Op {
		case "ping":
			out.send(event{ID: req.ID, Event: "pong"})
		case "exec":
			go runExec(req, out)
		case "mount_state":
			// Done inline: nothing else should run until the sandbox is ready.
			created, err := mountState()
			e := event{ID: req.ID, Event: "state", Created: created}
			if err == nil {
				e.Files, e.Bytes = sandboxStats()
			}
			if err == nil && req.Watch {
				e.Decoys, err = startWatch(req.Live, out, req.ID)
			}
			if err != nil {
				e.Error = err.Error()
			}
			out.send(e)
		case "trace_stop":
			result, err := stopWatch()
			e := event{ID: req.ID, Event: "trace", Trace: &result}
			if err != nil {
				e.Error = err.Error()
			}
			out.send(e)
		case "save_state":
			n, err := saveState()
			e := event{ID: req.ID, Event: "state", Bytes: n}
			if err != nil {
				e.Error = err.Error()
			}
			out.send(e)
		case "shutdown":
			os.Exit(0)
		default:
			out.send(event{ID: req.ID, Event: "error", Error: "unknown op " + req.Op})
		}
	}
}

type streamWriter struct {
	out  *frameWriter
	id   int
	name string
}

func (s *streamWriter) Write(p []byte) (int, error) {
	for rest := p; len(rest) > 0; {
		n := min(len(rest), chunkSize)
		s.out.send(event{ID: s.id, Event: s.name, Data: bytes.Clone(rest[:n])})
		rest = rest[n:]
	}
	return len(p), nil
}

func runExec(req request, out *frameWriter) {
	exit := func(code int, timedOut bool, problem string) {
		out.send(event{ID: req.ID, Event: "exit", Code: &code, TimedOut: timedOut, Error: problem})
	}
	if len(req.Argv) == 0 {
		exit(126, false, "empty argv")
		return
	}

	var cmd *exec.Cmd
	root := sandboxRoot()
	if root == "" {
		cmd = exec.Command(req.Argv[0], req.Argv[1:]...)
	} else {
		// Look the program up inside the sandbox, not in the agent's ramdisk.
		path, err := resolveInRoot(root, req.Argv[0])
		if err != nil {
			exit(127, false, err.Error())
			return
		}
		cmd = &exec.Cmd{Path: path, Args: req.Argv}
	}
	cmd.Dir = "/work"
	if req.Cwd != "" {
		cmd.Dir = req.Cwd
	}
	cmd.Env = append([]string{"PATH=" + defaultPath, "HOME=/root", "TERM=dumb"}, proxyEnv()...)
	for k, v := range req.Env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	if req.Stdin != nil {
		cmd.Stdin = bytes.NewReader(req.Stdin)
	}
	cmd.Stdout = &streamWriter{out, req.ID, "stdout"}
	cmd.Stderr = &streamWriter{out, req.ID, "stderr"}
	// Own process group, so a timeout can kill the whole tree.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Chroot: root}
	// Do not hang forever on a background child that keeps the pipes open.
	cmd.WaitDelay = 2 * time.Second

	if err := cmd.Start(); err != nil {
		exit(127, false, err.Error())
		return
	}

	var timedOut atomic.Bool
	if req.TimeoutMs > 0 {
		timer := time.AfterFunc(time.Duration(req.TimeoutMs)*time.Millisecond, func() {
			timedOut.Store(true)
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		})
		defer timer.Stop()
	}

	_ = cmd.Wait()
	code := 126
	if state := cmd.ProcessState; state != nil {
		code = state.ExitCode()
		if ws, ok := state.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			code = 128 + int(ws.Signal())
		}
	}
	exit(code, timedOut.Load(), "")
}

func cString(chars []int8) string {
	b := make([]byte, 0, len(chars))
	for _, c := range chars {
		if c == 0 {
			break
		}
		b = append(b, byte(c))
	}
	return string(b)
}

// kernelRelease is shown in the live view, e.g. "6.18.60-0-virt aarch64".
func kernelRelease() string {
	var u syscall.Utsname
	if syscall.Uname(&u) != nil {
		return ""
	}
	return cString(u.Release[:]) + " " + cString(u.Machine[:])
}
