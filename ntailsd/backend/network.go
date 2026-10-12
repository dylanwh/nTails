package backend

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"golang.org/x/net/dns/dnsmessage"
	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/tsnet"
)

type Network struct {
	ControlURL string // empty means the default tailscale.com coordination server; immutable after construction
	dir        string // immutable after construction

	// Everything below is read from the RPC handler goroutine and written
	// from Connect's background connect-watcher goroutine concurrently --
	// guard it with mu. Use the Domain/Status/LoginURL methods to read it
	// from outside this file; direct field access is only safe here, in
	// backend, with mu held.
	mu              sync.Mutex
	domain          string // MagicDNS suffix, discovered from the control server on connect
	status          string
	err             *NetworkError // set exactly while status is "error"
	loginURL        string        // set once the control server hands back a sign-in URL
	srv             *tsnet.Server
	closing         <-chan struct{} // closed once a node shut down in the background (see setErrorFor) has finished
	disconnected    bool            // persisted: don't auto-reconnect at startup until explicitly connected
	forgotten       bool            // logged out (see Forget): never write meta.json again
	onConnectedOnce func()          // see NotifyOnConnected
}

// metaFile, in a network's state directory next to tsnet's own files, is
// what makes it a known network.
const metaFile = "meta.json"

func (n *Network) Domain() string {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.domain
}

func (n *Network) Status() string {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.status
}

// NetworkError is why a network's status is "error": Code says which step
// failed, Detail is tsnet's own description (too varied -- DNS, TLS, the
// control server's reply -- to reduce to codes, but worth showing as is).
type NetworkError struct {
	Code   string // "start_failed" or "connect_failed"; see docs/rpc-protocol.md
	Detail string
}

// StatusErr returns n's status together with why it's "error" (nil when it
// isn't), read under one lock so the two always agree.
func (n *Network) StatusErr() (string, *NetworkError) {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.status, n.err
}

func (n *Network) LoginURL() string {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.loginURL
}

type networkMeta struct {
	ControlURL   string `json:"controlURL,omitempty"`
	Domain       string `json:"domain,omitempty"`
	Disconnected bool   `json:"disconnected,omitempty"`
}

func NewNetwork(controlURL string) (*Network, error) {
	base, err := networksDir()
	if err != nil {
		return nil, err
	}
	dir := filepath.Join(base, uuid.NewString())
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	n := &Network{ControlURL: controlURL, dir: dir}
	return n, n.saveMeta()
}

// LoadNetworks rediscovers every network by scanning the state directory.
func LoadNetworks() ([]*Network, error) {
	base, err := networksDir()
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(base)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	var networks []*Network
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		dir := filepath.Join(base, e.Name())
		data, err := os.ReadFile(filepath.Join(dir, metaFile))
		if err != nil {
			continue
		}
		var m networkMeta
		if err := json.Unmarshal(data, &m); err != nil {
			continue
		}
		networks = append(networks, &Network{
			ControlURL:   m.ControlURL,
			domain:       m.Domain,
			status:       "disconnected", // accurate until/unless the caller auto-reconnects it
			dir:          dir,
			disconnected: m.Disconnected,
		})
	}
	return networks, nil
}

// ID is a stable identifier for n, suitable for referencing it across
// process boundaries (e.g. an RPC frontend). It's the UUID n's state
// directory is named after, so it's stable across restarts and available
// even before a login completes and Domain is known.
func (n *Network) ID() string { return filepath.Base(n.dir) }

func (n *Network) Headscale() bool { return n.ControlURL != "" }

func (n *Network) Connected() bool { return n.Status() == "connected" }

// WasDisconnected reports whether n was explicitly disconnected (or logged
// out) last session, as opposed to never having been connected yet. Callers
// use this to decide whether to auto-reconnect n at startup.
func (n *Network) WasDisconnected() bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.disconnected
}

func (n *Network) DisplayName() string {
	switch {
	case n.Domain() != "":
		return n.Domain()
	case n.Headscale():
		return n.ControlURL
	default:
		return "tailscale.com"
	}
}

// Connect starts n's tsnet node and reports its progress through onUpdate
// for as long as it runs, including later changes: a connected session that
// expires drops back to "waiting for login".
//
// onNeedsLogin (may be nil) is called whenever n starts needing a sign-in
// that no request prompted: always after it has been connected during this
// attempt (an expired session), and also for the first sign-in if prompted
// is false (e.g. an auto-reconnect at startup). A login_network or
// connect_network request passes prompted = true, since the client asked
// for that first sign-in itself.
func (n *Network) Connect(onUpdate func(), onNeedsLogin func(), prompted bool) {
	n.mu.Lock()
	n.disconnected = false
	n.mu.Unlock()
	_ = n.saveMeta()

	srv := &tsnet.Server{
		Hostname:   localHostname(),
		ControlURL: n.ControlURL,
		Dir:        n.dir,
		Logf:       func(string, ...any) {},
		UserLogf:   func(string, ...any) {},
	}
	// Replacing a previous node (a retry from "error") closes it first: two
	// nodes can't share one state directory.
	n.mu.Lock()
	old, closing := n.srv, n.closing
	n.srv = srv
	n.mu.Unlock()
	if old != nil {
		_ = old.Close()
	}
	n.update(srv, onUpdate, func() { n.status = "connecting" })

	// srv (not n.srv) is used for the rest of this goroutine: Disconnect/
	// Forget/Close/setErrorFor can concurrently set n.srv = nil from another goroutine
	// (the RPC handler) while this one is still in flight -- re-reading
	// n.srv later, e.g. at the eventual Up call, crashed on a nil receiver
	// when that race was hit: this goroutine can stall for minutes if tsnet
	// forks a child that hangs before completing exec, long enough for
	// Disconnect/Forget to reliably land on n.srv while this is in flight.
	// See localClient's OmitAuth and disableCorpDNS for why that fork
	// happens and how it's avoided. srv is also this attempt's identity:
	// every status change below goes through update(srv, ...), which drops
	// it once n.srv no longer is srv, so a cancelled or replaced attempt
	// can't overwrite a newer status or report on a removed network.
	go func() {
		if closing != nil {
			<-closing // a failed node still shutting down on this directory
		}
		ctx := context.Background()
		lc, err := localClient(srv)
		if err != nil {
			n.setErrorFor(srv, "start_failed", err, onUpdate)
			return
		}

		watcher, err := lc.WatchIPNBus(ctx, ipn.NotifyInitialState|ipn.NotifyNoPrivateKeys)
		if err != nil {
			n.setErrorFor(srv, "start_failed", err, onUpdate)
			return
		}
		go func() {
			defer watcher.Close()
			everConnected := false
			for {
				note, err := watcher.Next()
				if err != nil {
					return // srv closed
				}
				if note.BrowseToURL != nil && *note.BrowseToURL != "" {
					url := *note.BrowseToURL
					var wasWaiting bool
					if !n.update(srv, onUpdate, func() {
						wasWaiting = n.status == "waiting for login"
						n.loginURL = url
						n.status = "waiting for login"
					}) {
						return
					}
					if !wasWaiting && onNeedsLogin != nil && (everConnected || !prompted) {
						onNeedsLogin()
					}
				}
				if note.State == nil {
					continue
				}
				switch *note.State {
				case ipn.Running:
					if st, err := lc.StatusWithoutPeers(ctx); err == nil && st.CurrentTailnet != nil {
						n.mu.Lock()
						n.domain = st.CurrentTailnet.MagicDNSSuffix
						n.mu.Unlock()
						_ = n.saveMeta()
					}
					if !n.update(srv, onUpdate, func() { n.status = "connected" }) {
						return
					}
					everConnected = true
				case ipn.NeedsLogin:
					if !everConnected {
						continue // the first sign-in: Up drives it, and its URL arrives above
					}
					// The session expired mid-run. Report it now, before a
					// URL exists (loginUrl stays empty until one arrives
					// above), and ask for one, since unlike the first
					// sign-in nothing else will.
					var wasWaiting bool
					if !n.update(srv, onUpdate, func() {
						wasWaiting = n.status == "waiting for login"
						n.status = "waiting for login"
					}) {
						return
					}
					if !wasWaiting && onNeedsLogin != nil {
						onNeedsLogin()
					}
					if err := lc.StartLoginInteractive(ctx); err != nil {
						n.setErrorFor(srv, "connect_failed", err, onUpdate)
						return
					}
				}
			}
		}()

		disableCorpDNS(lc)
		if _, err := srv.Up(ctx); err != nil {
			n.setErrorFor(srv, "connect_failed", err, onUpdate)
		}
	}()
}

// localClient returns srv's LocalClient (starting srv if needed), set up the
// way every caller here needs it.
func localClient(srv *tsnet.Server) (*local.Client, error) {
	lc, err := srv.LocalClient()
	if err != nil {
		return nil, err
	}
	// tsnet's embedded LocalAPI listener is in-process (memnet) and never
	// checks the macOS auth token this would otherwise fetch -- without
	// this, every LocalClient call here forks `lsof` via
	// readMacosSameUserProof to look for the macOS GUI app, which is a
	// real fork-without-immediate-exec hazard in this heavily threaded
	// binary.
	lc.OmitAuth = true
	return lc, nil
}

// disableCorpDNS tells lc's node not to install the tailnet's DNS config
// into the machine's real resolver. We only use tsnet for outbound
// SOCKS5/ProxyCommand routing, never as this machine's system resolver --
// there's no reason for it to touch macOS's DNS config at all. Callers must
// do this before Up, which is what actually waits on the control server:
// doing it any later would race the one real network round-trip (the
// netmap fetch) that would otherwise trigger that push once connected.
func disableCorpDNS(lc *local.Client) {
	_, _ = lc.EditPrefs(context.Background(), &ipn.MaskedPrefs{
		Prefs:      ipn.Prefs{CorpDNS: false},
		CorpDNSSet: true,
	})
}

// Open opens a connection to addr through n's tailnet, for the ssh
// ProxyCommand listener and the local proxies to use once n is connected.
//
// A host name in addr is resolved by the tailnet's own DNS (see
// resolveInTailnet), never by public DNS: tsnet's Dial would otherwise look
// up any name that isn't a device (e.g. a Headscale extra_records entry) in
// the system's DNS and connect to whatever that returns over the regular
// internet -- a different server that happens to share the name.
func (n *Network) Open(ctx context.Context, network, addr string) (net.Conn, error) {
	n.mu.Lock()
	srv := n.srv
	n.mu.Unlock()
	if srv == nil {
		return nil, fmt.Errorf("network %s is not connected", n.DisplayName())
	}
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, err
	}
	if _, err := netip.ParseAddr(host); err != nil { // a hostname
		ip, err := resolveInTailnet(ctx, srv, host)
		if err != nil {
			return nil, err
		}
		addr = net.JoinHostPort(ip.String(), port)
	}
	return srv.Dial(ctx, network, addr)
}

// resolveInTailnet looks host up with the tailnet's DNS resolver (MagicDNS,
// 100.100.100.100), which answers device names, extra records, and split-DNS
// routes, and is authoritative for the tailnet's domain. It prefers an IPv4
// answer, and refuses a name it has no address for outright.
func resolveInTailnet(ctx context.Context, srv *tsnet.Server, host string) (netip.Addr, error) {
	lc, err := localClient(srv)
	if err != nil {
		return netip.Addr{}, err
	}
	fqdn := strings.TrimSuffix(host, ".") + "."
	for _, qtype := range []string{"A", "AAAA"} {
		msg, _, err := lc.QueryDNS(ctx, fqdn, qtype)
		if err != nil {
			return netip.Addr{}, fmt.Errorf("looking up %s in the tailnet's DNS: %w", host, err)
		}
		if ip, ok := firstAddress(msg); ok {
			return ip, nil
		}
	}
	return netip.Addr{}, fmt.Errorf("%s has no address in the tailnet's DNS", host)
}

// firstAddress returns the first A or AAAA record in the answer section of
// a DNS response (following whatever CNAMEs precede it).
func firstAddress(msg []byte) (netip.Addr, bool) {
	var p dnsmessage.Parser
	if _, err := p.Start(msg); err != nil {
		return netip.Addr{}, false
	}
	if err := p.SkipAllQuestions(); err != nil {
		return netip.Addr{}, false
	}
	for {
		h, err := p.AnswerHeader()
		if err != nil { // including dnsmessage.ErrSectionDone
			return netip.Addr{}, false
		}
		switch h.Type {
		case dnsmessage.TypeA:
			r, err := p.AResource()
			if err != nil {
				return netip.Addr{}, false
			}
			return netip.AddrFrom4(r.A), true
		case dnsmessage.TypeAAAA:
			r, err := p.AAAAResource()
			if err != nil {
				return netip.Addr{}, false
			}
			return netip.AddrFrom16(r.AAAA), true
		default:
			if err := p.SkipAnswer(); err != nil {
				return netip.Addr{}, false
			}
		}
	}
}

// detach makes n forget its current tsnet node, so that node's connect
// goroutine can no longer change n's status, and returns it for closing.
func (n *Network) detach() *tsnet.Server {
	n.mu.Lock()
	defer n.mu.Unlock()
	srv := n.srv
	n.srv = nil
	return srv
}

// Close shuts n's node down at exit. No status change is reported.
func (n *Network) Close() error {
	if srv := n.detach(); srv != nil {
		return srv.Close()
	}
	return nil
}

// Disconnect tears down n's tsnet connection without discarding its saved
// session, so a later Connect can resume without a fresh sign-in. Unlike
// Forget, n stays known to the registry and on disk. The choice persists
// across restarts via WasDisconnected: n won't be auto-reconnected at
// startup until explicitly connected again.
func (n *Network) Disconnect(onUpdate func()) {
	srv := n.detach()
	n.mu.Lock()
	n.disconnected = true
	n.mu.Unlock()

	if srv != nil {
		_ = srv.Close()
	}
	_ = n.saveMeta()
	n.update(nil, onUpdate, func() { n.status = "disconnected" })
}

// LogoutTimeout bounds how long Forget's logout waits on the control server.
const LogoutTimeout = 15 * time.Second

// Forget is the terminal action behind the "Logout" verb: unlike Disconnect,
// there's no entry left afterward to Connect back into. It immediately
// detaches n's node (so nothing reports on n again) and removes its
// meta.json (so n isn't loaded as a network again), then returns the slow
// part for the caller to run in the background -- and to wait for before
// exiting (the rpc server's shutdown does): logging out with the control
// server (best effort, bounded by LogoutTimeout), shutting the node down,
// and removing n's state directory.
func (n *Network) Forget() (finish func()) {
	n.mu.Lock()
	n.forgotten = true // no saveMeta from an attempt still in flight can bring n back
	srv, closing := n.srv, n.closing
	n.srv = nil
	n.mu.Unlock()
	_ = os.Remove(filepath.Join(n.dir, metaFile))
	return n.finishLogout(srv, closing)
}

// finishLogout is a logout's slow part (see Forget). If srv is nil (n is
// disconnected), it starts a temporary node from n's saved state just to
// tell the control server, so the session is invalidated there too -- after
// any node still shutting down on the same directory (closing) has finished.
func (n *Network) finishLogout(srv *tsnet.Server, closing <-chan struct{}) func() {
	return func() {
		if srv == nil {
			if closing != nil {
				<-closing
			}
			srv = &tsnet.Server{
				Hostname:   localHostname(),
				ControlURL: n.ControlURL,
				Dir:        n.dir,
				Logf:       func(string, ...any) {},
				UserLogf:   func(string, ...any) {},
			}
		}
		if lc, err := localClient(srv); err == nil {
			ctx, cancel := context.WithTimeout(context.Background(), LogoutTimeout)
			if err := lc.Logout(ctx); err != nil {
				log.Printf("network %s: logout: %v", n.ID(), err)
			}
			cancel()
		} else {
			log.Printf("network %s: starting node to log out: %v", n.ID(), err)
		}
		_ = srv.Close()
		_ = os.RemoveAll(n.dir)
	}
}

// NotifyOnConnected arranges for cb to be called (once, then forgotten) the
// next time n reaches "connected", independent of whatever callbacks were
// passed to Connect. This lets a login dialog opened well after Connect was
// first called (e.g. reopened by clicking a row still "waiting for login")
// still auto-close when login succeeds.
func (n *Network) NotifyOnConnected(cb func()) {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.onConnectedOnce = cb
}

// setErrorFor ends srv's attempt in "error": n stops tracking srv (so its
// watcher can't move n out of "error" on its own) and srv is shut down.
// connect_network starts a fresh attempt.
func (n *Network) setErrorFor(srv *tsnet.Server, code string, err error, onUpdate func()) {
	closed := make(chan struct{})
	if n.update(srv, onUpdate, func() {
		n.status = "error"
		n.err = &NetworkError{Code: code, Detail: err.Error()}
		n.srv = nil
		n.closing = closed // the next node on this directory waits for it
	}) {
		// Closed off this goroutine: it may be srv's own watcher.
		go func() {
			_ = srv.Close()
			close(closed)
		}()
	}
}

// update applies a status change under n.mu and reports it through
// onUpdate. With a non-nil srv, it's a change from that connect attempt and
// is dropped (returning false) unless srv is still n's node. It also keeps
// the fields tied to a status consistent: err only while "error", loginURL
// only while "waiting for login".
func (n *Network) update(srv *tsnet.Server, onUpdate func(), apply func()) bool {
	n.mu.Lock()
	if srv != nil && n.srv != srv {
		n.mu.Unlock()
		return false
	}
	apply()
	if n.status != "error" {
		n.err = nil
	}
	if n.status != "waiting for login" {
		n.loginURL = ""
	}
	var cb func()
	if n.status == "connected" && n.onConnectedOnce != nil {
		cb = n.onConnectedOnce
		n.onConnectedOnce = nil
	}
	n.mu.Unlock()

	onUpdate()
	if cb != nil {
		cb()
	}
	return true
}

// saveMeta writes n's meta.json, unless n has been forgotten (logged out).
// It holds n.mu through the write so it can't race Forget's removal and
// bring a logged-out network back on the next launch.
func (n *Network) saveMeta() error {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.forgotten {
		return nil
	}
	meta := networkMeta{ControlURL: n.ControlURL, Domain: n.domain, Disconnected: n.disconnected}
	data, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(n.dir, metaFile), data, 0o600)
}

// localHostname is the system hostname suffixed with "-ntails" to identify this
// machine's ntails node in each tailnet.
func localHostname() string {
	host, err := os.Hostname()
	if err != nil || host == "" {
		host = "ntails"
	}
	if i := strings.IndexByte(host, '.'); i >= 0 {
		host = host[:i]
	}
	return sanitizeHostname(host) + "-ntails"
}

func sanitizeHostname(s string) string {
	return strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '-':
			return r
		case r >= 'A' && r <= 'Z':
			return r + ('a' - 'A')
		default:
			return '-'
		}
	}, s)
}

func appDir() (string, error) {
	base, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(base, "ntails")
	return dir, os.MkdirAll(dir, 0o700)
}

func networksDir() (string, error) {
	base, err := appDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(base, "networks")
	return dir, os.MkdirAll(dir, 0o700)
}

// NetworkRegistry is a collection of Networks shared, and mutated, by both the
// UI and the ssh ProxyCommand/SOCKS5 listeners' goroutines.
type NetworkRegistry struct {
	mu       sync.Mutex
	networks []*Network
}

func (r *NetworkRegistry) Add(n *Network) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.networks = append(r.networks, n)
}

func (r *NetworkRegistry) Remove(n *Network) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for i, x := range r.networks {
		if x == n {
			r.networks = append(r.networks[:i], r.networks[i+1:]...)
			return
		}
	}
}

// All returns a snapshot safe to range over without holding the lock.
func (r *NetworkRegistry) All() []*Network {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]*Network, len(r.networks))
	copy(out, r.networks)
	return out
}

// Resolve finds the network whose discovered MagicDNS suffix matches host,
// for routing an ssh ProxyCommand connection to the right tailnet.
func (r *NetworkRegistry) Resolve(host string) *Network {
	for _, n := range r.All() {
		if d := n.Domain(); d != "" && (host == d || strings.HasSuffix(host, "."+d)) {
			return n
		}
	}
	return nil
}

// dialViaRegistry resolves host (parsed out of addr) against registry by
// MagicDNS suffix and dials out through that network. Shared by the ssh
// ProxyCommand listener and the SOCKS5 proxy.
func dialViaRegistry(ctx context.Context, registry *NetworkRegistry, network, addr string) (net.Conn, error) {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, err
	}
	n := registry.Resolve(host)
	if n == nil {
		return nil, fmt.Errorf("no network matches host %s", host)
	}
	if !n.Connected() {
		return nil, fmt.Errorf("network %s is not connected (status: %s)", n.DisplayName(), n.Status())
	}
	return n.Open(ctx, network, addr)
}
