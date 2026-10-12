package backend

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
)

// ProxySettings configures the three local listeners LocalProxy owns. Each
// port also accepts two sentinels: PortOff (-1) disables that listener
// entirely, and PortAuto (0) starts it on a port the OS picks -- the actual
// bound port is then only knowable at runtime, via LocalProxy.Effective.
type ProxySettings struct {
	SOCKS int `json:"socks"`
	PAC   int `json:"pac"`
	HTTP  int `json:"http"`
}

const (
	PortOff  = -1
	PortAuto = 0
)

const (
	defaultSOCKSPort = 1080
	defaultPACPort   = 1081
	defaultHTTPPort  = 1082
)

func settingsPath() (string, error) {
	dir, err := appDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "config.json"), nil
}

func LoadSettings() ProxySettings {
	s := ProxySettings{SOCKS: defaultSOCKSPort, PAC: defaultPACPort, HTTP: defaultHTTPPort}
	path, err := settingsPath()
	if err != nil {
		return s
	}
	if data, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(data, &s)
	}
	return s
}

// SaveSettings writes s to the config file atomically: a temp file renamed
// over it, so a failed write never leaves a truncated config behind.
func SaveSettings(s ProxySettings) error {
	path, err := settingsPath()
	if err != nil {
		return err
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), "config-*.json.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name()) // no-op once renamed
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

func listenLocal(port int) (net.Listener, error) {
	return net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
}
