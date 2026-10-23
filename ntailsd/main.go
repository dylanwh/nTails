package main

import (
	"errors"
	"fmt"
	"log"
	"os"
	"runtime/debug"

	"github.com/spf13/cobra"

	"github.com/dylanwh/ntails/ntailsd/backend"
	"github.com/dylanwh/ntails/ntailsd/rpc"
)

// Set by the release build via -ldflags "-X main.version=vX.Y.Z"; empty for
// local builds, which then report Go's own build info.
var version string

func buildVersion() string {
	if version != "" {
		return version
	}
	if info, ok := debug.ReadBuildInfo(); ok && info.Main.Version != "" {
		return info.Main.Version
	}
	return "unknown"
}

func main() {
	root := &cobra.Command{
		Use:     "ntailsd",
		Short:   "Connect to multiple tailnets at once",
		Version: buildVersion(),
	}

	root.AddCommand(&cobra.Command{
		Use:   "connect <host> <port>",
		Short: "ssh ProxyCommand helper",
		Long: "This command's standard input and output are forwarded to host on\n" +
			"port over the tailnet corresponding to the MagicDNS suffix. This is\n" +
			"intended to be used by ssh_config's ProxyCommand:\n\n" +
			"  Host *.<your-tailnet-domain>\n" +
			"      ProxyCommand /path/to/ntailsd connect %h %p",
		Args: cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			os.Exit(backend.RunConnect(args[0], args[1]))
			return nil
		},
	})

	root.AddCommand(&cobra.Command{
		Use:   "rpc",
		Short: "Run the backend as a JSON-Lines RPC server over stdin/stdout",
		Long: "Speaks a line-delimited JSON protocol on stdin/stdout so a native,\n" +
			"per-platform GUI can drive ntailsd.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			registry, localProxy, stopServices, initialProxyErr := setup()
			rpc.Run(registry, localProxy, stopServices, initialProxyErr)
			return nil
		},
	})

	if err := root.Execute(); err != nil {
		os.Exit(1)
	}
}

// setup starts the proxy listener, local proxy, and loads saved networks and
// settings. initialProxyErr joins one *backend.ProxyConfigError per local
// proxy listener that failed to start (e.g. a configured port already in
// use); the rest still run. Recoverable via save_settings, so it's returned
// for the caller to surface rather than treated as fatal here.
func setup() (registry *backend.NetworkRegistry, localProxy *backend.LocalProxy, stopServices func(), initialProxyErr error) {
	registry = &backend.NetworkRegistry{}
	var stops []func()

	// Also doubles as the single-instance lock. Losing it is the one failure
	// the client hears about as a "fatal" event (docs/rpc-protocol.md); any
	// other ProxyCommand listener failure is only logged.
	if stop, err := backend.StartProxyListener(registry); err != nil {
		if errors.Is(err, backend.ErrAlreadyRunning) {
			fmt.Fprintln(os.Stderr, "ntailsd: already running")
			rpc.Fatal("already_running")
			os.Exit(1)
		}
		log.Printf("proxy listener: %v", err)
	} else {
		stops = append(stops, stop)
	}

	cfg := backend.LoadConfig()
	localProxy = backend.NewLocalProxy(registry)
	localProxy.SetPassword(cfg.Password)
	initialProxyErr = localProxy.Start(cfg.ProxySettings)

	if loaded, err := backend.LoadNetworks(); err == nil {
		for _, n := range loaded {
			registry.Add(n)
		}
	}

	stopServices = func() {
		localProxy.Stop()
		for _, stop := range stops {
			stop()
		}
	}
	return registry, localProxy, stopServices, initialProxyErr
}
