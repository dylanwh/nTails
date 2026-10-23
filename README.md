# nTails - The easiest way to access more than one tailnet at once

nTails is a third-party, unofficial client for tailscale networks. Its primary
purpose is to allow you to access resources from multiple tailnets
simultaneously. It is built on the very cool [tsnet][] package and operates
entirely in userspace. It offers HTTP and SOCKS5 proxies for browsers and an ssh
[ProxyCommand][].

There are frontends for all of the major operating systems, including:

- emacs
- macOS
- Windows

## How it works

The official Tailscale client puts your whole machine on one tailnet. Switching
between tailnets is easy enough, but if you use tailscale and your friend also
uses tailscale, you cannot access resources from both networks at the same
time.

nTails instead runs a small userspace node per tailnet and exposes them through
local proxies:

- a SOCKS5 proxy (default port 1080)
- a PAC file (default port 1081), so browsers and the OS proxy setting can route
  only `*.ts.net` (or `*.default.horse`) names through it and leave everything
  else alone
- an HTTP proxy (default port 1082)

Each tailnet is identified by its [MagicDNS][] name.

Headscale works too. Point a tailnet at any control server URL and mix it with
tailscale.com tailnets freely.

### ssh

`ntailsd connect` is an ssh [ProxyCommand][]. The frontends can write the block
for you, or you can add it yourself:

```
Host *.your-tailnet.ts.net
    ProxyCommand /path/to/ntailsd connect %h %p
```

After that, `ssh host.your-tailnet.ts.net` goes over the tailnet with no other
changes.

## Parts

Everything is driven by one backend, `ntailsd`, which the frontends run as a
subprocess and talk to over a small JSON protocol
([rpc-protocol.md](https://github.com/dylanwh/nTails/blob/main/docs/rpc-protocol.md)).

| Directory    | What it is                                                        |
|--------------|-------------------------------------------------------------------|
| `ntailsd/`   | The Go backend. Runs the tailnets, the proxies, and `connect`.    |
| `ntails.el/` | A native Elisp client for GNU Emacs. `M-x ntails-network-list`.   |
| `nTails/`    | A native SwiftUI app for the Apple Macintosh.                     |
| `wintails/`  | A native Win32 app for Microsoft Windows.                         |
| `docs/`      | The website and the RPC protocol spec.                            |

## Install

### emacs

Our tier-1 operating system. `ntails.el` lives in a subdirectory, so the
recipe has to say so.

use-package, Emacs 30 or later:

```elisp
(use-package ntails
  :vc (:url "https://github.com/dylanwh/nTails" :lisp-dir "ntails.el"))
```

Doom:

```elisp
(package! ntails
  :recipe (:host github :repo "dylanwh/nTails" :files ("ntails.el/ntails.el")))
```

Spacemacs, in `dotspacemacs-additional-packages`:

```elisp
(ntails :location (recipe :fetcher github :repo "dylanwh/nTails"
                          :files ("ntails.el/ntails.el")))
```

It runs `ntailsd` as a subprocess, so unpack a `ntailsd` archive from the
[releases page][releases] and put it on your `PATH` first.

Then `M-x ntails-network-list`. `a` adds a tailnet and opens a sign-in buffer
with a QR code to scan from your phone (`s` sets the proxy ports; `M-x
ntails-set-proxy-password` sets a proxy password). The QR code needs the
[qrencode][] package from GNU ELPA, which package managers install for you.

To send Emacs' own HTTP requests (eww, package.el, and anything else built on
`url-retrieve`) to hosts on your tailnets through `ntailsd`, the same way the
PAC file does for browsers:

```elisp
(setq url-proxy-locator #'ntails-find-proxy-for-url)
```

If you set a proxy password (`M-x ntails-set-proxy-password`), `ntails.el`
automatically registers the credentials (`ntails` and your password) in
`url-http-proxy-basic-auth-storage` for the running HTTP proxy port, so
`url-retrieve` authenticates without prompting.

### macOS

Download `nTails.app` from the [releases page][releases]. It bundles `ntailsd`.

### Windows

Download the winTails installer (`wintails-*.msi`) from the [releases page][releases]. It can even
auto-configure the proxy for you.

### Linux

Coming soon. Until then, the emacs frontend works on Linux today.

## Building

```
make build          # ntailsd, for this machine
make msi            # wintails.exe, ntailsd.exe, and wintails.msi, cross-built (needs nix)
ci/build-release.sh v0.0.0-local   # ntailsd archives for every platform, into dist/
```

`ntailsd` is pure Go with no cgo, so one machine cross-compiles all of it.
wintails cross-compiles too, from `wintails/shell.nix`. The macOS app needs
Xcode; see `nTails/`.

## Disclaimer

nTails is not affiliated with, endorsed by, or supported by Tailscale Inc.

## License

[MPL-2.0](https://github.com/dylanwh/nTails/blob/main/LICENSE).

[tsnet]: https://pkg.go.dev/tailscale.com/tsnet
[MagicDNS]: https://tailscale.com/kb/1081/magicdns
[ProxyCommand]: https://man.openbsd.org/ssh_config#ProxyCommand
[releases]: https://github.com/dylanwh/nTails/releases/latest
[qrencode]: https://elpa.gnu.org/packages/qrencode.html
