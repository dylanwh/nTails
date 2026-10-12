package backend

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

var ErrAlreadyRunning = errors.New("ntailsd is already running")

func socketPath() (string, error) {
	dir, err := appDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "ntailsd.sock"), nil
}

// ntailsd connect %h %p
func RunConnect(host, port string) int {
	path, err := socketPath()
	if err != nil {
		fmt.Fprintf(os.Stderr, "ntailsd: %v\n", err)
		return 1
	}

	conn, err := net.Dial("unix", path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ntailsd: is the app running? %v\n", err)
		return 1
	}
	defer conn.Close()

	fmt.Fprintf(conn, "CONNECT %s %s\n", host, port)

	reader := bufio.NewReader(conn)
	resp, err := reader.ReadString('\n')
	if err != nil {
		fmt.Fprintf(os.Stderr, "ntailsd: %v\n", err)
		return 1
	}
	if !strings.HasPrefix(resp, "OK") {
		fmt.Fprint(os.Stderr, "ntailsd: "+strings.TrimPrefix(resp, "ERR "))
		return 1
	}

	splice(conn, reader, os.Stdin, os.Stdout)
	return 0
}

func StartProxyListener(registry *NetworkRegistry) (stop func(), err error) {
	path, err := socketPath()
	if err != nil {
		return nil, err
	}

	if conn, derr := net.DialTimeout("unix", path, 200*time.Millisecond); derr == nil {
		conn.Close()
		return nil, ErrAlreadyRunning
	}
	_ = os.Remove(path) // clear a stale socket left by an unclean previous exit

	ln, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				// A deliberate shutdown closes ln itself (the stop closure
				// below), which is the expected, silent way to get here. Any
				// other error (e.g. a transient fd exhaustion) must not
				// leave this goroutine dead while ln stays open: that would
				// make the single-instance lock this socket doubles as
				// unreliable -- a later launch's dial would find nothing
				// answering and conclude, wrongly, that it's safe to steal
				// the socket path out from under a still-running process.
				if !errors.Is(err, net.ErrClosed) {
					log.Printf("proxy listener: accept: %v", err)
				}
				ln.Close()
				return
			}
			go handleProxyConn(conn, registry)
		}
	}()

	return func() {
		ln.Close()
		_ = os.Remove(path)
	}, nil
}

func handleProxyConn(conn net.Conn, registry *NetworkRegistry) {
	defer conn.Close()

	reader := bufio.NewReader(conn)
	line, err := reader.ReadString('\n')
	if err != nil {
		return
	}
	parts := strings.Fields(line)
	if len(parts) != 3 || parts[0] != "CONNECT" {
		fmt.Fprintf(conn, "ERR bad request\n")
		return
	}
	host, port := parts[1], parts[2]

	dst, err := dialViaRegistry(context.Background(), registry, "tcp", net.JoinHostPort(host, port))
	if err != nil {
		fmt.Fprintf(conn, "ERR %v\n", err)
		return
	}
	defer dst.Close()

	fmt.Fprintf(conn, "OK\n")
	splice(dst, dst, reader, conn)
}

func splice(upstreamW io.Writer, downstreamR io.Reader, upstreamR io.Reader, downstreamW io.Writer) {
	closeSafe := func(i any) {
		if c, ok := i.(io.Closer); ok {
			c.Close()
		}
	}

	defer closeSafe(upstreamW)
	defer closeSafe(downstreamR)
	defer closeSafe(upstreamR)
	defer closeSafe(downstreamW)

	errs := make(chan error, 2)

	go func() {
		_, err := io.Copy(upstreamW, upstreamR)
		errs <- err
	}()
	go func() {
		_, err := io.Copy(downstreamW, downstreamR)
		errs <- err
	}()

	if err := <-errs; err != nil && !errors.Is(err, net.ErrClosed) && !errors.Is(err, os.ErrClosed) {
		log.Printf("splice error: %v", err)
	}
}
