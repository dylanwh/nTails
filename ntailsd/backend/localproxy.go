package backend

import (
	"context"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"slices"
	"strings"
	"sync/atomic"

	"tailscale.com/net/socks5"
)

const proxyUser = "ntails"

// proxyAuth holds the local proxies' shared password, atomically swappable
// without rebinding either listener.
type proxyAuth struct {
	p atomic.Pointer[string]
}

func (a *proxyAuth) Get() string {
	if p := a.p.Load(); p != nil {
		return *p
	}
	return ""
}

func (a *proxyAuth) Set(password string) {
	a.p.Store(&password)
}

// oneConnListener hands a single already-accepted net.Conn to socks5.Server.Serve
// (the only entry point tailscale.com/net/socks5 exports), so each connection
// gets a Server configured with the password in effect when it arrived,
// without rebinding the listening socket on a password-only Reload.
type oneConnListener struct {
	conn net.Conn
}

func (l *oneConnListener) Accept() (net.Conn, error) {
	if l.conn == nil {
		return nil, net.ErrClosed
	}
	c := l.conn
	l.conn = nil
	return c, nil
}

func (l *oneConnListener) Close() error   { return nil }
func (l *oneConnListener) Addr() net.Addr { return nil }

// Each start* function binds port, which may be PortAuto (0, letting the OS
// pick), and reports back the actual bound port -- the requested one, or
// whatever the OS assigned.

func startSOCKSProxy(registry *NetworkRegistry, port int, auth *proxyAuth) (stop func(), boundPort int, err error) {
	// addr arrives exactly as the client sent it, name or IP, so routing by
	// MagicDNS suffix sees the name.
	dialer := func(ctx context.Context, network, addr string) (net.Conn, error) {
		conn, err := dialViaRegistry(ctx, registry, network, addr)
		if err != nil {
			log.Printf("socks5: %v", err)
		}
		return conn, err
	}

	ln, err := listenLocal(port)
	if err != nil {
		return nil, 0, err
	}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			srv := &socks5.Server{Dialer: dialer}
			if p := auth.Get(); p != "" {
				srv.Username = proxyUser
				srv.Password = p
			}
			_ = srv.Serve(&oneConnListener{conn: c})
		}
	}()
	return func() { ln.Close() }, ln.Addr().(*net.TCPAddr).Port, nil
}

// pacTargets holds the *effective* SOCKS and HTTP proxy ports the PAC file
// points at -- PortOff for one that's disabled, which the generated PAC file
// then leaves out. Read at request time rather than captured by value, so
// the PAC file stays current even on a Reload that doesn't restart the PAC
// listener itself (see LocalProxy).
type pacTargets struct {
	socks atomic.Int32
	http  atomic.Int32
}

func startPACServer(registry *NetworkRegistry, port int, targets *pacTargets) (stop func(), boundPort int, err error) {
	mux := http.NewServeMux()
	mux.HandleFunc("/proxy.pac", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/x-ns-proxy-autoconfig")
		httpFirst := r.URL.Query().Has("http")
		w.Write([]byte(generatePAC(registry, int(targets.socks.Load()), int(targets.http.Load()), httpFirst)))
	})

	ln, err := listenLocal(port)
	if err != nil {
		return nil, 0, err
	}
	srv := &http.Server{Handler: mux}
	go srv.Serve(ln)
	return stopHTTPServer(srv, ln), ln.Addr().(*net.TCPAddr).Port, nil
}

// stopHTTPServer returns a stop func that releases ln's port right away.
// srv.Close alone doesn't if the Serve goroutine hasn't registered ln yet
// (Serve then closes it only once it runs), which made a Reload that hands
// this port to another listener straight after starting it fail to bind.
func stopHTTPServer(srv *http.Server, ln net.Listener) func() {
	return func() {
		srv.Close()
		ln.Close()
	}
}

// startHTTPProxy serves a standard forward HTTP proxy: CONNECT tunnels
// (hijacked and spliced raw, for HTTPS and other TCP traffic) and plain
// absolute-URI HTTP requests (round-tripped through a dialer scoped to this
// one request, same as SOCKS dials fresh per connection).
func startHTTPProxy(registry *NetworkRegistry, port int, auth *proxyAuth) (stop func(), boundPort int, err error) {
	srv := &http.Server{Handler: httpProxyHandler(registry, auth)}

	ln, err := listenLocal(port)
	if err != nil {
		return nil, 0, err
	}
	go srv.Serve(ln)
	return stopHTTPServer(srv, ln), ln.Addr().(*net.TCPAddr).Port, nil
}

func validProxyAuth(header, wantPass string) bool {
	const prefix = "Basic "
	if len(header) < len(prefix) || !strings.EqualFold(header[:len(prefix)], prefix) {
		return false
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(header[len(prefix):]))
	if err != nil {
		return false
	}
	user, pass, ok := strings.Cut(string(raw), ":")
	// Compare both halves unconditionally in constant time, same as
	// tailscale.com/net/socks5, so neither length nor early mismatch leaks
	// through timing to another local process.
	userMatch := subtle.ConstantTimeCompare([]byte(user), []byte(proxyUser))
	passMatch := subtle.ConstantTimeCompare([]byte(pass), []byte(wantPass))
	return ok && userMatch == 1 && passMatch == 1
}

func httpProxyHandler(registry *NetworkRegistry, auth *proxyAuth) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if want := auth.Get(); want != "" && !validProxyAuth(r.Header.Get("Proxy-Authorization"), want) {
			w.Header().Set("Proxy-Authenticate", `Basic realm="ntails"`)
			http.Error(w, http.StatusText(http.StatusProxyAuthRequired), http.StatusProxyAuthRequired)
			return
		}
		if r.Method == http.MethodConnect {
			handleHTTPConnect(w, r, registry)
			return
		}
		handleHTTPForward(w, r, registry)
	}
}

func handleHTTPConnect(w http.ResponseWriter, r *http.Request, registry *NetworkRegistry) {
	dst, err := dialViaRegistry(r.Context(), registry, "tcp", r.Host)
	if err != nil {
		log.Printf("http proxy: %v", err)
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}

	hijacker, ok := w.(http.Hijacker)
	if !ok {
		dst.Close()
		http.Error(w, "CONNECT not supported", http.StatusInternalServerError)
		return
	}
	conn, bufrw, err := hijacker.Hijack()
	if err != nil {
		dst.Close()
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if _, err := bufrw.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil || bufrw.Flush() != nil {
		dst.Close()
		conn.Close()
		return
	}
	splice(dst, dst, bufrw.Reader, conn)
}

func handleHTTPForward(w http.ResponseWriter, r *http.Request, registry *NetworkRegistry) {
	host := r.Host
	if _, _, err := net.SplitHostPort(host); err != nil {
		host = net.JoinHostPort(host, "80")
	}

	outReq := r.Clone(r.Context())
	outReq.RequestURI = ""
	outReq.Header.Del("Proxy-Authorization")

	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return dialViaRegistry(ctx, registry, network, host)
		},
	}
	resp, err := transport.RoundTrip(outReq)
	if err != nil {
		log.Printf("http proxy: %v", err)
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	for k, vv := range resp.Header {
		for _, v := range vv {
			w.Header().Add(k, v)
		}
	}
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body)
}

// ProxyConfigError reports that one of the local proxy listeners (identified
// by Field, matching ProxySettings' JSON tags "socks"/"pac"/"http") could not
// be started -- typically its configured port is already in use by
// something else. This is a recoverable configuration problem: at startup
// the rpc server reports it to the client as an "invalid_config" event so
// the user can pick a different port via save_ports.
type ProxyConfigError struct {
	Field string
	Err   error
}

func (e *ProxyConfigError) Error() string { return e.Field + ": " + e.Err.Error() }
func (e *ProxyConfigError) Unwrap() error { return e.Err }

// Listener slots, in ProxySettings order. Ports and stop funcs are kept per
// slot so Start, Reload, and rollback share one code path.
const (
	slotSOCKS = iota
	slotPAC
	slotHTTP
	numSlots
)

// slotNames match ProxySettings' JSON tags, which ProxyConfigError.Field uses.
var slotNames = [numSlots]string{"socks", "pac", "http"}

// bindOrder starts HTTP before PAC, so the PAC file knows both of its targets
// from the moment it starts serving.
var bindOrder = [numSlots]int{slotSOCKS, slotHTTP, slotPAC}

func (s ProxySettings) port(slot int) int {
	switch slot {
	case slotSOCKS:
		return s.SOCKS
	case slotPAC:
		return s.PAC
	default:
		return s.HTTP
	}
}

func (s *ProxySettings) setPort(slot, port int) {
	switch slot {
	case slotSOCKS:
		s.SOCKS = port
	case slotPAC:
		s.PAC = port
	default:
		s.HTTP = port
	}
}

// LocalProxy owns the SOCKS5, PAC, and HTTP listeners. Its Reload only
// rebinds whichever port actually changed, binding each replacement before
// stopping the listener it replaces, so a changed listener has no gap. The
// one exception is a port moving from one listener to another in the same
// Reload (e.g. swapping socks and pac): the listener giving that port up has
// to stop first, or the one taking it over would collide with ntails' own
// socket.
type LocalProxy struct {
	registry  *NetworkRegistry
	current   ProxySettings // as requested: may contain PortOff/PortAuto
	effective ProxySettings // as actually bound: PortOff, or the real listening port

	auth       proxyAuth
	pacTargets pacTargets
	stops      [numSlots]func()
}

func NewLocalProxy(registry *NetworkRegistry) *LocalProxy {
	return &LocalProxy{registry: registry}
}

// Effective reports the ports actually bound right now: PortOff for a
// disabled listener, otherwise the real port, even if it was requested as
// PortAuto. Safe to call between Start/Reload calls, which happen on the
// same goroutine as any command handler calling this.
func (p *LocalProxy) Effective() ProxySettings {
	return p.effective
}

// Current reports the settings actually applied as requested. It matches
// what Start or the last successful Reload was given, except that a
// listener that failed to start at launch is PortOff. Reloading to it
// restores exactly the listeners running now.
func (p *LocalProxy) Current() ProxySettings {
	return p.current
}

func (p *LocalProxy) startSlot(slot, port int) (stop func(), bound int, err error) {
	switch slot {
	case slotSOCKS:
		return startSOCKSProxy(p.registry, port, &p.auth)
	case slotPAC:
		return startPACServer(p.registry, port, &p.pacTargets)
	default:
		return startHTTPProxy(p.registry, port, &p.auth)
	}
}

// SetPassword changes the password the SOCKS5 and HTTP listeners require,
// effective on their next connection; an empty password disables
// authentication. Independent of Start/Reload: it never rebinds a listener.
func (p *LocalProxy) SetPassword(password string) {
	p.auth.Set(password)
}

func (p *LocalProxy) storePACTargets() {
	p.pacTargets.socks.Store(int32(p.effective.SOCKS))
	p.pacTargets.http.Store(int32(p.effective.HTTP))
}

// Start binds whichever of the three listeners have a port other than
// PortOff, for the first time. Each is independent: one that fails to bind
// is left off and the others still start. The returned error joins one
// *ProxyConfigError per failure. A failed listener's p.current is reset to
// PortOff, so a later Reload with the same settings sees it as a change
// and tries it again.
func (p *LocalProxy) Start(s ProxySettings) error {
	var errs []error
	p.current = s
	p.effective = ProxySettings{SOCKS: PortOff, PAC: PortOff, HTTP: PortOff}

	for _, slot := range bindOrder {
		if slot == slotPAC {
			p.storePACTargets()
		}
		port := s.port(slot)
		if port == PortOff {
			continue
		}
		stop, bound, err := p.startSlot(slot, port)
		if err != nil {
			errs = append(errs, &ProxyConfigError{Field: slotNames[slot], Err: err})
			p.current.setPort(slot, PortOff)
			continue
		}
		p.stops[slot] = stop
		p.effective.setPort(slot, bound)
	}
	return errors.Join(errs...)
}

// DuplicatePortError reports that a requested port is the one another
// listener, whose setting isn't changing, is actually bound to (typically a
// PortAuto port that happened to get it).
type DuplicatePortError struct {
	Fields [2]string // the listener asking for the port, then the one holding it
}

func (e *DuplicatePortError) Error() string {
	return e.Fields[0] + " and " + e.Fields[1] + " would share a port"
}

// Reload switches to s. A port that didn't change (including a PortAuto
// port staying PortAuto, which is left on whatever port the OS gave it
// before, or a PortAuto port now requested as the port it already has) is
// left running untouched.
//
// It's all or nothing. persist (may be nil) runs once every new listener is
// bound but before any old one is stopped; if binding fails (a
// *ProxyConfigError) or persist does (its error, returned as is), every
// listener is put back as it was -- on the exact ports it had.
func (p *LocalProxy) Reload(s ProxySettings, persist func() error) error {
	var changed [numSlots]bool
	for slot := range numSlots {
		port := s.port(slot)
		changed[slot] = port != p.current.port(slot) && !(port > 0 && port == p.effective.port(slot))
	}
	for slot := range numSlots {
		port := s.port(slot)
		if !changed[slot] || port <= 0 {
			continue
		}
		for other := range numSlots {
			if other != slot && !changed[other] && p.effective.port(other) == port {
				return &DuplicatePortError{Fields: [2]string{slotNames[slot], slotNames[other]}}
			}
		}
	}

	// Stop first any changed listener whose current port another changed
	// listener is about to take over.
	var stoppedEarly [numSlots]bool
	for old := range numSlots {
		oldPort := p.effective.port(old)
		if !changed[old] || oldPort <= 0 {
			continue
		}
		for next := range numSlots {
			if next != old && changed[next] && s.port(next) == oldPort {
				stopIfSet(p.stops[old])
				p.stops[old] = nil
				stoppedEarly[old] = true
				break
			}
		}
	}

	var fresh [numSlots]func() // listeners bound by this Reload
	next := p.effective
	for _, slot := range bindOrder {
		if !changed[slot] {
			continue
		}
		next.setPort(slot, PortOff)
		port := s.port(slot)
		if port == PortOff {
			continue
		}
		stop, bound, err := p.startSlot(slot, port)
		if err != nil {
			for _, f := range fresh {
				stopIfSet(f)
			}
			p.restartStoppedEarly(stoppedEarly)
			return &ProxyConfigError{Field: slotNames[slot], Err: err}
		}
		fresh[slot] = stop
		next.setPort(slot, bound)
	}
	if persist != nil {
		if err := persist(); err != nil {
			for _, f := range fresh {
				stopIfSet(f)
			}
			p.restartStoppedEarly(stoppedEarly)
			return err
		}
	}

	for slot := range numSlots {
		if !changed[slot] {
			continue
		}
		if !stoppedEarly[slot] {
			stopIfSet(p.stops[slot])
		}
		p.stops[slot] = fresh[slot]
	}
	p.current = s
	p.effective = next
	p.storePACTargets()
	return nil
}

// restartStoppedEarly undoes Reload's early stops after a failed switch,
// rebinding each listener on the exact port it had. If that port has been
// taken in the meantime, the listener is left off and recorded as PortOff
// in p.current, so the next Reload tries it again, as after a failed Start.
func (p *LocalProxy) restartStoppedEarly(stoppedEarly [numSlots]bool) {
	for slot := range numSlots {
		if !stoppedEarly[slot] {
			continue
		}
		stop, _, err := p.startSlot(slot, p.effective.port(slot))
		if err != nil {
			log.Printf("local proxy: couldn't restore %s on port %d: %v", slotNames[slot], p.effective.port(slot), err)
			p.current.setPort(slot, PortOff)
			p.effective.setPort(slot, PortOff)
			continue
		}
		p.stops[slot] = stop
	}
	p.storePACTargets()
}

func stopIfSet(stop func()) {
	if stop != nil {
		stop()
	}
}

func (p *LocalProxy) Stop() {
	for slot := range numSlots {
		stopIfSet(p.stops[slot])
	}
}

func generatePAC(registry *NetworkRegistry, socksPort, httpPort int, httpFirst bool) string {
	var proxies []string
	if socksPort > 0 {
		proxies = append(proxies, fmt.Sprintf("SOCKS5 127.0.0.1:%d", socksPort))
	}
	if httpPort > 0 {
		proxies = append(proxies, fmt.Sprintf("PROXY 127.0.0.1:%d", httpPort))
	}
	if httpFirst {
		slices.Reverse(proxies)
	}

	var rules strings.Builder
	if len(proxies) > 0 {
		route := strings.Join(proxies, "; ")
		for _, n := range registry.All() {
			// A disconnected tailnet keeps its domain, but routing it to a
			// proxy that would only refuse it is worse than DIRECT.
			domain := n.Domain()
			if domain == "" || !n.Connected() {
				continue
			}
			fmt.Fprintf(&rules, "  if (dnsDomainIs(host, %q)) return %q;\n", "."+domain, route)
		}
	}
	return fmt.Sprintf("function FindProxyForURL(url, host) {\n%s  return \"DIRECT\";\n}\n", rules.String())
}
