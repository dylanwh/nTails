// Package rpc is a stdin/stdout JSON-Lines frontend for ntails, letting a
// native per-platform GUI drive the backend. docs/rpc-protocol.md is the
// spec this implements.
package rpc

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"time"

	ps "github.com/mitchellh/go-ps"

	"github.com/dylanwh/ntails/ntailsd/backend"
)

// maxLineBytes caps a request line. A longer one is read to its end,
// discarded, and answered invalid_request rather than ending the session.
const maxLineBytes = 1 << 20

type request struct {
	ID   *int64
	Cmd  string
	Args json.RawMessage // nil when absent
}

type response struct {
	Type  string    `json:"type"`
	ID    *int64    `json:"id"` // null only when an invalid_request's id couldn't be read
	OK    bool      `json:"ok"`
	Data  any       `json:"data,omitempty"`
	Error *rpcError `json:"error,omitempty"`
}

// rpcError is a failed response's "error" (and the "invalid_config" and
// "fatal" events' data): a snake_case Code plus whichever extra fields that
// code defines. A Network in "error" status carries one too. Every code and
// its fields are listed in docs/rpc-protocol.md. Anything only a human would
// want (an OS error, a JSON parse position) goes to the stderr log instead --
// except a network error's Detail, tsnet's own description, which is worth
// showing.
type rpcError struct {
	Code   string   `json:"code"`
	Field  string   `json:"field,omitempty"`  // invalid_args, invalid_port, port_unavailable
	Fields []string `json:"fields,omitempty"` // duplicate_port
	ID     string   `json:"id,omitempty"`     // network_not_found
	Status string   `json:"status,omitempty"` // invalid_state
	Cmd    string   `json:"cmd,omitempty"`    // unknown_command
	Detail string   `json:"detail,omitempty"` // start_failed, connect_failed
}

// portUnavailable turns a LocalProxy bind failure into its rpcError, or
// "internal" for anything that isn't one.
func portUnavailable(err error) *rpcError {
	var cfgErr *backend.ProxyConfigError
	if errors.As(err, &cfgErr) {
		return &rpcError{Code: "port_unavailable", Field: cfgErr.Field}
	}
	return &rpcError{Code: "internal"}
}

type event struct {
	Type string `json:"type"`
	Name string `json:"name"`
	Data any    `json:"data"`
}

type notificationDTO struct {
	Title string `json:"title"`
	Body  string `json:"body"`
}

type networkDTO struct {
	ID         string    `json:"id"`
	ControlURL string    `json:"controlUrl"`
	Domain     string    `json:"domain"`
	Status     string    `json:"status"`
	LoginURL   string    `json:"loginUrl"`
	Error      *rpcError `json:"error,omitempty"` // present exactly when Status is "error"
}

// settingsDTO is get_settings'/save_settings' response. Requested is what's
// configured (may hold PortOff/PortAuto) and is exactly what save_settings
// takes, so a client can round-trip it through an edit form without turning
// PortAuto into whatever port it happened to get. Effective is what's
// actually bound right now.
type settingsDTO struct {
	Requested backend.ProxySettings `json:"requested"`
	Effective backend.ProxySettings `json:"effective"`
}

func toDTO(n *backend.Network) networkDTO {
	status, netErr := n.StatusErr()
	dto := networkDTO{
		ID:         n.ID(),
		ControlURL: n.ControlURL,
		Domain:     n.Domain(),
		Status:     status,
		LoginURL:   n.LoginURL(),
	}
	if netErr != nil {
		dto.Error = &rpcError{Code: netErr.Code, Detail: netErr.Detail}
	}
	return dto
}

// Proxy is the part of *backend.LocalProxy the server drives (an interface
// so tests can substitute a fake).
type Proxy interface {
	// Reload switches listeners all or nothing, running persist between
	// binding the new ones and retiring the old (see LocalProxy.Reload).
	Reload(s backend.ProxySettings, persist func() error) error
	Effective() backend.ProxySettings
}

// Fatal writes a "fatal" event carrying code to stdout -- the only line a
// server that can't run at all sends -- for the caller to then exit.
func Fatal(code string) {
	_ = json.NewEncoder(os.Stdout).Encode(event{Type: "event", Name: "fatal", Data: &rpcError{Code: code}})
}

func Run(registry *backend.NetworkRegistry, proxy Proxy, stopServices func(), initialProxyErr error) {
	s := newServer(registry, proxy, stopServices, os.Stdout)
	if initialProxyErr != nil {
		log.Printf("local proxy: %v", initialProxyErr)
		// One event per listener that failed (Start joins their errors).
		failures := []error{initialProxyErr}
		if joined, ok := initialProxyErr.(interface{ Unwrap() []error }); ok {
			failures = joined.Unwrap()
		}
		for _, err := range failures {
			s.emit("invalid_config", portUnavailable(err))
		}
	}
	for _, n := range registry.All() {
		if n.WasDisconnected() {
			continue // user left it disconnected; respect that across restarts
		}
		// Nothing asked for this reconnect, so even its first sign-in
		// prompt is unprompted.
		n.Connect(s.onNetworkUpdate(n), s.onNeedsLogin(n), false)
	}
	// Windows doesn't reparent orphans, so the getppid check could never
	// fire there; stdin EOF is the only signal (docs/rpc-protocol.md).
	if runtime.GOOS != "windows" {
		go s.watchForOrphan()
	}
	go watchForSelfClone()
	s.readLoop(os.Stdin)
	s.shutdown()
}

func newServer(registry *backend.NetworkRegistry, proxy Proxy, stopServices func(), out io.Writer) *server {
	return &server{
		registry:     registry,
		proxy:        proxy,
		stopServices: stopServices,
		loadSettings: backend.LoadSettings,
		saveSettings: backend.SaveSettings,
		enc:          json.NewEncoder(out),
	}
}

// watchForOrphan exits the process if our parent ever changes from who
// launched us -- i.e. it died without us seeing EOF on stdin, the normal
// detection path (closing is supposed to close its write end of our stdin
// pipe, which the kernel guarantees even on a SIGKILL/crash, but this is a
// second, independent check in case that pipe plumbing ever doesn't hold,
// or a frontend process hangs around without actually reading/writing).
// A dead parent reparents us to launchd/init, which never matches the pid
// we started with.
func (s *server) watchForOrphan() {
	parent := os.Getppid()
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for range ticker.C {
		if os.Getppid() != parent {
			log.Printf("rpc: parent process (pid %d) is gone, exiting", parent)
			s.shutdown()
			os.Exit(0)
		}
	}
}

// watchForSelfClone kills any process that is both a direct child of this
// one and running our own executable -- the signature of a fork() that
// never completed its following exec() (observed after tsnet's DNS manager
// shells out to scutil on connect.
// We never legitimately spawn a child of ourselves, so finding one here is
// unambiguous. Uses go-ps, which queries the process table directly via
// Darwin's sysctl() syscall; shelling out to `ps` ourselves would add
// another exec call to the same risk class this is guarding against.
func watchForSelfClone() {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	self := os.Getpid()
	name := filepath.Base(exe)
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		procs, err := ps.Processes()
		if err != nil {
			continue
		}
		for _, p := range procs {
			if p.Pid() == self || p.PPid() != self {
				continue
			}
			if p.Executable() != name {
				continue
			}
			log.Printf("rpc: killing pid %d, a child of us (%d) running our own executable", p.Pid(), self)
			if proc, err := os.FindProcess(p.Pid()); err == nil {
				_ = proc.Kill()
			}
		}
	}
}

// shutdown releases every resource the server holds. It runs whether
// readLoop returned because the client sent "quit" or because stdin simply
// closed — e.g. the frontend crashed, was force-quit, or was killed by a
// debugger without a chance to say goodbye. A frontend's exit (for any
// reason) closes its end of the stdin pipe, which is EOF here; treating
// that identically to an explicit quit means the backend never outlives a
// frontend that disappeared uncleanly, with no cooperation required from
// the frontend side. Nothing is written after this starts (see closed), and
// it waits, bounded, for background logouts to finish so a quit right after
// logout_network doesn't cut the logout short.
func (s *server) shutdown() {
	s.mu.Lock()
	s.closed = true
	s.mu.Unlock()
	s.stopServices()
	for _, n := range s.registry.All() {
		n.Close()
	}
	done := make(chan struct{})
	go func() { s.forgetting.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(backend.LogoutTimeout + 5*time.Second):
		log.Printf("rpc: gave up waiting for logouts to finish")
	}
}

type server struct {
	registry     *backend.NetworkRegistry
	proxy        Proxy
	stopServices func()
	// The config file, swappable so tests don't touch the real one.
	loadSettings func() backend.ProxySettings
	saveSettings func(backend.ProxySettings) error

	forgetting sync.WaitGroup // background logouts (Network.Forget) still running

	// mu guards enc and closed: handle() and each Network's background
	// goroutines all write. Everything a line carries is built while holding
	// it (see emitFn/respondFn), so lines go out in the order the state they
	// describe changed: a later line is never older than an earlier one.
	mu     sync.Mutex
	enc    *json.Encoder
	closed bool // set with the quit response, or at EOF; nothing is written after
}

func (s *server) known(n *backend.Network) bool {
	return s.find(n.ID()) == n
}

func (s *server) onNetworkUpdate(n *backend.Network) func() {
	return func() {
		s.emitFn("network_changed", func() any {
			if !s.known(n) {
				return nil // removed: no event mentions its id again
			}
			return toDTO(n)
		})
	}
}

// onNeedsLogin is the notification for a network needing sign-in that no
// request prompted (see Network.Connect).
func (s *server) onNeedsLogin(n *backend.Network) func() {
	return func() {
		s.emitFn("notification", func() any {
			if !s.known(n) {
				return nil
			}
			body := n.DisplayName() + " needs you to sign in"
			if n.Domain() != "" { // it has been connected before
				body = n.DisplayName() + " needs you to sign in again"
			}
			return notificationDTO{Title: "ntails", Body: body}
		})
	}
}

func (s *server) find(id string) *backend.Network {
	for _, n := range s.registry.All() {
		if n.ID() == id {
			return n
		}
	}
	return nil
}

// findByIDArgs decodes req.Args as {"id": "..."} and looks it up, responding
// with an error itself (so callers just propagate a false return) if the
// args are malformed or no such network exists.
func (s *server) findByIDArgs(req request) (*backend.Network, bool) {
	var args struct {
		ID string `json:"id"`
	}
	if e := decodeArgs(req.Args, &args, "id"); e != nil {
		s.fail(req, e, nil)
		return nil, false
	}
	if args.ID == "" {
		s.fail(req, &rpcError{Code: "invalid_args", Field: "id"}, nil)
		return nil, false
	}
	n := s.find(args.ID)
	if n == nil {
		s.fail(req, &rpcError{Code: "network_not_found", ID: args.ID}, nil)
		return nil, false
	}
	return n, true
}

// decodeArgs decodes raw into dst, requiring exactly keys (case-sensitive):
// each present, nothing else. encoding/json alone would quietly zero a
// missing field and match keys case-insensitively.
func decodeArgs(raw json.RawMessage, dst any, keys ...string) *rpcError {
	var m map[string]json.RawMessage
	if len(raw) == 0 || json.Unmarshal(raw, &m) != nil || m == nil {
		return &rpcError{Code: "invalid_args"} // missing, null, or not an object
	}
	allowed := make(map[string]bool, len(keys))
	for _, k := range keys {
		allowed[k] = true
		if _, ok := m[k]; !ok {
			return &rpcError{Code: "invalid_args", Field: k}
		}
	}
	for k, v := range m {
		if !allowed[k] {
			return &rpcError{Code: "invalid_args", Field: k}
		}
		if string(bytes.TrimSpace(v)) == "null" {
			return &rpcError{Code: "invalid_args"} // the wrong type; encoding/json would zero it
		}
	}
	if json.Unmarshal(raw, dst) != nil {
		return &rpcError{Code: "invalid_args"} // a value of the wrong type
	}
	return nil
}

// noArgs rejects args on a command that takes none.
func noArgs(req request) *rpcError {
	if req.Args != nil {
		return &rpcError{Code: "invalid_args"}
	}
	return nil
}

// readLine reads one '\n'-terminated line (the final one may lack it),
// without the newline. A line longer than maxLineBytes is consumed to its
// end and reported as tooLong, with no content.
func readLine(r *bufio.Reader) (line []byte, tooLong bool, err error) {
	for {
		chunk, err := r.ReadSlice('\n')
		if !tooLong {
			// The line ending (\n or \r\n) doesn't count toward the limit.
			content := len(line) + len(bytes.TrimSuffix(chunk, []byte("\n")))
			if bytes.HasSuffix(chunk, []byte("\r\n")) {
				content--
			}
			if content > maxLineBytes {
				tooLong, line = true, nil
			} else {
				line = append(line, chunk...)
			}
		}
		if err == bufio.ErrBufferFull {
			continue
		}
		if err != nil && (len(line) > 0 || tooLong) && err == io.EOF {
			err = nil // a final unterminated line still counts
		}
		return bytes.TrimSuffix(line, []byte("\n")), tooLong, err
	}
}

func (s *server) readLoop(in io.Reader) {
	r := bufio.NewReaderSize(in, 64*1024)
	for {
		line, tooLong, err := readLine(r)
		if err != nil {
			if err != io.EOF {
				log.Printf("rpc: reading stdin: %v", err)
			}
			return
		}
		if tooLong {
			s.fail(request{}, &rpcError{Code: "invalid_request"}, fmt.Errorf("line over %d bytes", maxLineBytes))
			continue
		}
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		// Every request line gets a response, even one that can't be
		// dispatched -- otherwise a client waits forever on a reply that
		// never comes.
		req, e, detail := parseRequest(line)
		if e != nil {
			s.fail(req, e, detail)
			continue
		}
		if s.handle(req) {
			return
		}
	}
}

// parseRequest reads a request envelope: exactly id (an integer), cmd (a
// non-empty string), and optionally args. The id is returned whenever it
// was readable, even if something else about the line is invalid, so the
// invalid_request can still echo it.
func parseRequest(line []byte) (request, *rpcError, error) {
	var req request
	var m map[string]json.RawMessage
	if err := json.Unmarshal(line, &m); err != nil || m == nil {
		return req, &rpcError{Code: "invalid_request"}, fmt.Errorf("not a JSON object: %v", err)
	}
	if raw, ok := m["id"]; ok {
		var id int64
		if json.Unmarshal(raw, &id) == nil {
			req.ID = &id
		}
	}
	for k := range m {
		if k != "id" && k != "cmd" && k != "args" {
			return req, &rpcError{Code: "invalid_request"}, fmt.Errorf("unexpected key %q", k)
		}
	}
	if raw, ok := m["cmd"]; ok {
		_ = json.Unmarshal(raw, &req.Cmd)
	}
	if req.ID == nil || req.Cmd == "" {
		return req, &rpcError{Code: "invalid_request"}, fmt.Errorf("need an integer id and a cmd: %s", line)
	}
	if raw, ok := m["args"]; ok {
		req.Args = raw
	}
	return req, nil, nil
}

func (s *server) handle(req request) (quit bool) {
	switch req.Cmd {
	case "list_networks":
		if e := noArgs(req); e != nil {
			s.fail(req, e, nil)
			return false
		}
		s.respondFn(req.ID, func() any {
			networks := s.registry.All()
			dtos := make([]networkDTO, len(networks))
			for i, n := range networks {
				dtos[i] = toDTO(n)
			}
			return dtos
		})

	case "get_settings":
		if e := noArgs(req); e != nil {
			s.fail(req, e, nil)
			return false
		}
		// The config file is the source of truth for what was requested,
		// and stays right even if the initial Start failed.
		s.respond(req.ID, settingsDTO{s.loadSettings(), s.proxy.Effective()})

	case "login_network":
		var args struct {
			ControlURL string `json:"controlUrl"`
		}
		if e := decodeArgs(req.Args, &args, "controlUrl"); e != nil {
			s.fail(req, e, nil)
			return false
		}
		n, err := backend.NewNetwork(args.ControlURL)
		if err != nil { // couldn't create the network's state directory/metadata
			s.fail(req, &rpcError{Code: "storage_failed"}, err)
			return false
		}
		s.registry.Add(n)
		n.Connect(s.onNetworkUpdate(n), s.onNeedsLogin(n), true)
		s.respondFn(req.ID, func() any { return toDTO(n) })

	case "connect_network":
		n, ok := s.findByIDArgs(req)
		if !ok {
			return false
		}
		if status := n.Status(); status != "disconnected" && status != "error" {
			s.fail(req, &rpcError{Code: "invalid_state", Status: status}, nil)
			return false
		}
		n.Connect(s.onNetworkUpdate(n), s.onNeedsLogin(n), true)
		s.respond(req.ID, nil)

	case "disconnect_network":
		n, ok := s.findByIDArgs(req)
		if !ok {
			return false
		}
		if status := n.Status(); status == "disconnected" {
			s.fail(req, &rpcError{Code: "invalid_state", Status: status}, nil)
			return false
		}
		n.Disconnect(s.onNetworkUpdate(n))
		s.respond(req.ID, nil)

	case "logout_network":
		n, ok := s.findByIDArgs(req)
		if !ok {
			return false
		}
		id := n.ID()
		// Forget detaches n (no more events) and drops it from disk before
		// anything is sent; the slow logout runs in the background.
		finish := n.Forget()
		s.registry.Remove(n)
		s.respond(req.ID, nil)
		s.emit("network_removed", struct {
			ID string `json:"id"`
		}{id})
		s.forgetting.Add(1)
		go func() {
			defer s.forgetting.Done()
			finish()
		}()
		return false

	case "save_settings":
		s.saveSettingsCmd(req)

	case "quit":
		if e := noArgs(req); e != nil {
			s.fail(req, e, nil)
			return false
		}
		s.mu.Lock()
		_ = s.enc.Encode(response{Type: "res", ID: req.ID, OK: true})
		s.closed = true // in the same critical section: nothing follows the quit response
		s.mu.Unlock()
		return true

	default:
		s.fail(req, &rpcError{Code: "unknown_command", Cmd: req.Cmd}, nil)
	}
	return false
}

// saveSettingsCmd is all or nothing (docs/rpc-protocol.md, "Saving
// settings"): validation first, in a fixed order, then the switch, then the
// config write -- and if the write fails, the switch is undone.
func (s *server) saveSettingsCmd(req request) {
	var next backend.ProxySettings
	if e := decodeArgs(req.Args, &next, "socks", "pac", "http"); e != nil {
		s.fail(req, e, nil)
		return
	}
	ports := [3]struct {
		name string
		port int
	}{{"socks", next.SOCKS}, {"pac", next.PAC}, {"http", next.HTTP}}
	for _, p := range ports {
		if p.port < backend.PortOff || p.port > 65535 {
			s.fail(req, &rpcError{Code: "invalid_port", Field: p.name}, nil)
			return
		}
	}
	for i := range ports {
		for j := i + 1; j < len(ports); j++ {
			if ports[i].port > 0 && ports[i].port == ports[j].port {
				s.fail(req, &rpcError{Code: "duplicate_port", Fields: []string{ports[i].name, ports[j].name}}, nil)
				return
			}
		}
	}

	// Bind the new ports, then write the config, then retire the old
	// listeners: a collision only surfaces at bind time, and saving first
	// would leave a config that fails again on every restart. Reload undoes
	// everything, keeping each old listener's exact port, if either fails.
	err := s.proxy.Reload(next, func() error { return s.saveSettings(next) })
	var cfgErr *backend.ProxyConfigError
	var dupErr *backend.DuplicatePortError
	switch {
	case err == nil:
		s.respond(req.ID, settingsDTO{next, s.proxy.Effective()})
	case errors.As(err, &dupErr):
		s.fail(req, &rpcError{Code: "duplicate_port", Fields: dupErr.Fields[:]}, nil)
	case errors.As(err, &cfgErr):
		s.fail(req, portUnavailable(err), err)
	default: // persist failed
		s.fail(req, &rpcError{Code: "storage_failed"}, err)
	}
}

func (s *server) respond(id *int64, data any) {
	s.respondFn(id, func() any { return data })
}

// respondFn sends a success response whose data is built while holding
// s.mu (see server.mu).
func (s *server) respondFn(id *int64, build func() any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	_ = s.enc.Encode(response{Type: "res", ID: id, OK: true, Data: build()})
}

// fail sends e as req's error response. detail, if any, is the underlying
// cause, which only goes to the stderr log -- the wire carries just e.
func (s *server) fail(req request, e *rpcError, detail error) {
	if detail != nil {
		log.Printf("rpc: %s: %s: %v", req.Cmd, e.Code, detail)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	_ = s.enc.Encode(response{Type: "res", ID: req.ID, OK: false, Error: e})
}

func (s *server) emit(name string, data any) {
	s.emitFn(name, func() any { return data })
}

// emitFn sends an event whose data is built while holding s.mu (see
// server.mu); a nil result sends nothing.
func (s *server) emitFn(name string, build func() any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	if data := build(); data != nil {
		_ = s.enc.Encode(event{Type: "event", Name: name, Data: data})
	}
}
