# ntails RPC Protocol

`ntailsd rpc` runs the backend as a JSON-Lines RPC server. A frontend drives it
over the subprocess's stdin and stdout, sending commands and receiving responses
and asynchronous events. This document specifies that wire protocol.

## Transport

The server MUST read from stdin and write to stdout. Both MUST carry UTF-8
text, one JSON object per line, terminated by either `\n` or `\r\n`, with no
other framing.
stderr is unstructured and reserved for logging; it MUST NOT carry protocol
data.

The server MAY write to stdout before it has read anything (see
`invalid_config` and `fatal` under [Events](#events)), so a client MUST start
reading stdout as soon as it launches the server.

A line MUST NOT exceed 1MiB, excluding its trailing `\n` or `\r\n`.

## Envelope

Every line the client sends is a request.

Every line the server sends is a response or an event, distinguished by
`"type"`.

**Request** (client -> server):
```json
{
  "id": 1,
  "cmd": "login_network",
  "args": {
    "controlUrl": ""
  }
}
```
A request has exactly these keys: `id`, `cmd`, and `args` when the command takes any. `id` is an integer (in the signed 64-bit range) chosen by the client, unique among its outstanding requests; its only purpose is matching each response to its request. `args` is an object whose keys are exactly the ones the command documents: every listed key is required, keys are case-sensitive, and any other key is an error. `args` is omitted for commands that take none.

**Response** (server -> client, one per request, echoing its `id`):
```json
{
  "type": "res",
  "id": 1,
  "ok": true,
  "data": {
    "id": "a1b2...",
    "status": "connecting"
  }
}
{
  "type": "res",
  "id": 2,
  "ok": true
}
{
  "type": "res",
  "id": 3,
  "ok": false,
  "error": {
    "code": "duplicate_port",
    "fields": [
      "socks",
      "pac"
    ]
  }
}
```

A successful response carries its result in `data`; a command with no result
omits `data` entirely. A failed response has `error` (an `Error`, see
[Errors](#errors)) in place of `data`.

Responses are not guaranteed to arrive in the order their requests were sent,
and events may arrive at any point, including between a request and its
response. Lines are written in the order the state they describe changed,
though: data in a response (such as a `Network`) is never older than an event
written before it, and anything written after it is newer, so a client can
simply apply each line as it arrives.

If stdout closes without a `fatal` event, the server has exited unexpectedly
(for example, it crashed): treat every outstanding request as failed.

Every request line gets exactly one response, including one the server can't
dispatch. A line gets an `invalid_request` error if it:

- isn't valid JSON,
- exceeds the line length limit (see [Transport](#transport); the server discards it and keeps running), or
- lacks an integer `id` or a non-empty string `cmd`, or has any other key.

The `id` is echoed whenever it could be read as an integer, and is `null`
otherwise; an over-long line is never parsed, so its `id` is always `null`.
That's the only time a response's `id` is `null`.

Two exceptions: blank lines are ignored, and nothing after a `quit` request is
read or answered.

**Event** (server -> client, no `id`, unsolicited):
```json
{
  "type": "event",
  "name": "network_changed",
  "data": {...}
}
```

## Commands

| `cmd`                | `args`                                | `data` on success                                                                                                                                                                                                                                                                                                                                                                                                                                         |
|----------------------|---------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `list_networks`      | none                                  | `Network[]` — snapshot of every known network, in no particular order (`[]` if there are none)                                                                                                                                                                                                                                                                                                                                                            |
| `get_ports`          | none                                  | `ProxyStatus` — what's configured and what's actually bound right now (see `ProxyStatus` below)                                                                                                                                                                                                                                                                                                                                                           |
| `get_proxy_password` | none                                  | `{password}` — the local proxies' shared password, `""` for none; see [Local proxies](#local-proxies)                                                                                                                                                                                                                                                                                                                                                    |
| `login_network`      | `{controlUrl}` (`""` = tailscale.com) | `Network` — creates a new tailnet entry and immediately begins connecting. `controlUrl` isn't validated up front: a bad one shows up later as the network's `error`. Its `status` is `connecting` or a later one; sign-in (if needed) completes asynchronously, see Events below                                                                                                                                                                          |
| `connect_network`    | `{id}`                                | none — valid when `status` is `disconnected` or `error`; fails otherwise. Behaves like `login_network`'s connect step but for an existing entry: reuses a saved session silently if one exists, otherwise goes through `waiting for login` same as a fresh one. From `error`, this is how a client retries                                                                                                                                                |
| `disconnect_network` | `{id}`                                | none — tears down the tailnet connection without discarding its session; `status` becomes `disconnected`. Valid from any status except `disconnected` itself (including `connecting`/`waiting for login`/`error`, as a way to cancel). A later `connect_network` resumes without a fresh sign-in                                                                                                                                                          |
| `logout_network`     | `{id}`                                | none — the terminal action. Valid from any status, with no `connect_network` back into it afterward. Fires a `network_removed` event, then continues in the background: it tells the control server to invalidate the session (best effort, starting the tailnet node briefly if it isn't running; if that fails, the server is never told), shuts down the connection, and always forgets the entry and its local state. `quit` waits for this to finish |
| `save_ports`         | `ProxySettings` (all three keys)      | `ProxyStatus` — the new configuration and the resulting bound ports, so a caller that requested `0` for a port learns what the OS actually picked without a separate `get_ports` round trip. All or nothing; see [Saving ports](#saving-ports)                                                                                                                                                                                                             |
| `set_proxy_password` | `{password}`                          | `{password}` — the password now in effect; see [Local proxies](#local-proxies). Independent of `save_ports`: it never touches `socks`/`pac`/`http`, and no listener rebinds                                                                                                                                                                                                                                                                                  |
| `quit`               | none                                  | none — the server responds, cleans up, and exits. If a `logout_network` is still finishing in the background, it waits for that first (up to about 20 seconds), so a client should allow at least that long before killing it                                                                                                                                                                                                                             |

Any command can fail instead, returning `{"ok":false,"error":{...}}` in place of
`data`; see [Errors](#errors) for what each command can return.

## Errors

An `Error` is an object with a `code`, a snake_case word, plus whatever fields
that code defines below. The table lists every code the server can send. There's
no free-form message: a client branches on `code` and writes its own wording.
The one exception is a network error's `detail`, described under `Network`.
Underlying details only a human would want, such as an OS error, go to the
server's stderr log. A client should handle a `code` it doesn't recognize like
`internal`, so new codes can be added without breaking it.

| `code`              | Fields   | Sent by                                                   | Meaning                                                                                                                                                                                                                                                                          |
|---------------------|----------|-----------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `invalid_request`   | —        | any request line                                          | the line couldn't be read as a request (see [Envelope](#envelope)); `id` may be `null`                                                                                                                                                                                           |
| `invalid_args`      | `field`? | any command                                               | `args` doesn't match what the command documents: a key is missing or not allowed (`field` names it), `id` is empty (`field` is `"id"`), or, with no `field`, `args` is missing or not an object, is present on a command that takes none, or a value is `null` or the wrong type |
| `unknown_command`   | `cmd`    | any                                                       | `cmd` isn't a command this server knows                                                                                                                                                                                                                                          |
| `network_not_found` | `id`     | `connect_network`, `disconnect_network`, `logout_network` | no network has that `id`                                                                                                                                                                                                                                                         |
| `invalid_state`     | `status` | `connect_network`, `disconnect_network`                   | the network's current `status` doesn't allow this: `connect_network` needs `disconnected` or `error`, `disconnect_network` needs anything but `disconnected`                                                                                                                     |
| `invalid_port`      | `field`  | `save_ports`                                              | the port for `field` (`"socks"`, `"pac"`, or `"http"`) isn't `-1`, `0`, or 1–65535                                                                                                                                                                                               |
| `duplicate_port`    | `fields` | `save_ports`                                              | the two listeners named in `fields` would share a port: both asked for the same one (`> 0`), or the first asked for the port the second, whose setting isn't changing, is actually bound to (e.g. one it auto-picked)                                                            |
| `port_unavailable`  | `field`  | `save_ports`, `invalid_config` event                      | the port for `field` couldn't be bound because something outside ntails holds it. From `save_ports`, nothing changed; `field` may name a listener the save didn't change, since one that failed at startup is retried by every save                                              |
| `invalid_password`  | —        | `set_proxy_password`                                      | `password` is over 255 bytes, the limit RFC 1929's SOCKS5 username/password subnegotiation can carry                                                                                                                                                                              |
| `storage_failed`    | —        | `login_network`, `save_ports`, `set_proxy_password`       | the server couldn't write its own files, e.g. the disk is full or its data folder isn't writable. Nothing changed: no network was added, or no settings were applied                                                                                                             |
| `start_failed`      | `detail` | a `Network`'s `error`                                     | the network's local tailnet node couldn't start; `detail` is the underlying reason, for display                                                                                                                                                                                  |
| `connect_failed`    | `detail` | a `Network`'s `error`                                     | the node started but couldn't come up with the control server (unreachable, rejected, etc.); `detail` is the underlying reason, for display                                                                                                                                      |
| `already_running`   | —        | `fatal` event                                             | another ntailsd is already running for this user, so this one is exiting                                                                                                                                                                                                         |
| `internal`          | —        | any                                                       | a failure the server doesn't expect, i.e. a bug. Not sent by any known path today; also how clients treat any `code` they don't recognize                                                                                                                                        |

## Events

| `name`            | `data`          | fires when                                                                                                                                                                                                                                                                                                                                                               |
|-------------------|-----------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `network_changed` | `Network`       | at least whenever a network's `status`, `domain`, `loginUrl`, or `error` changes (it may also repeat with unchanged data) — covers the full lifecycle: `disconnected` -> `connecting` -> `waiting for login` -> `connected`, or `error`; `connected` back to `waiting for login` if the session needs signing in again; and back to `disconnected` via `disconnect_network` |
| `network_removed` | `{id}`          | a network is logged out of (`logout_network`). No event mentions that `id` again                                                                                                                                                                                                                                                                                         |
| `notification`    | `{title, body}` | a network needs the user to sign in without any request having prompted it: an auto-reconnect at startup, or a connected network whose session expired. Free-form text for display; it accompanies the `network_changed` to `waiting for login` rather than replacing it                                                                                                 |
| `invalid_config`  | `Error`         | at startup, a configured listener couldn't be started. Currently always `port_unavailable`, naming its `field`. That listener is off; the others are unaffected. One event per listener that failed, sent before anything else (see [Startup failures](#startup-failures))                                                                                               |
| `fatal`           | `Error`         | the server can't run and is about to exit (exit code 1) without reading any request. Currently always `already_running`. It's the only line the server writes                                                                                                                                                                                                            |

A client should treat `network_changed` as authoritative and upsert by `id`;
it's the only place a login URL ever appears (there is no separate command to
fetch one). Show a sign-in prompt while `status` is `waiting for login`, using
the current `loginUrl`, which may change while waiting. It can also be `""`
briefly when a session expires, before the new URL arrives; show a "waiting"
state until it does.

No events are sent after the response to `quit`.

## Types

**`Network`**
```json
{
  "id": "a1b2c3d4-...",
  "controlUrl": "",
  "domain": "tailc7714.ts.net",
  "status": "connected",
  "loginUrl": ""
}
```

`id` is stable across restarts. `domain` is empty until the control server
assigns a MagicDNS suffix, and is kept from then on. Headscale vs. tailscale.com
is derivable from `controlUrl` being non-empty. `loginUrl` is non-empty only
while `status` is `waiting for login` (and may briefly be empty even then; see
[Events](#events)).

`status` is always one of:

| `status`            | Meaning                                                                     |
|---------------------|-----------------------------------------------------------------------------|
| `disconnected`      | not connected; stays that way until `connect_network`                       |
| `connecting`        | starting up and reaching the control server                                 |
| `waiting for login` | the user needs to sign in at `loginUrl`                                     |
| `connected`         | up and routing; can drop back to `waiting for login` if the session expires |
| `error`             | connecting failed; `error` says why (see below). `connect_network` retries  |

`error` is an `Error` (see [Errors](#errors)) that's present exactly when
`status` is `error`, and absent otherwise:

```json
{
  "id": "a1b2c3d4-...",
  "controlUrl": "",
  "domain": "",
  "status": "error",
  "loginUrl": "",
  "error": {
    "code": "connect_failed",
    "detail": "dial tcp: lookup controlplane.tailscale.com: no such host"
  }
}
```

Its `code` is `start_failed` or `connect_failed`. Unlike a command's error, it also carries `detail`: the underlying tailnet library's own description, which is too varied to reduce to codes but is meant to be shown to the user as is.

**`ProxySettings`**
```json
{
  "socks": 1080,
  "pac": 1081,
  "http": 1082
}
```
These are also the defaults when nothing has been saved yet. Each port also accepts two sentinel values:
- `-1` turns that listener off entirely.
- `0` starts it on a port the OS picks (useful to avoid a fixed-port collision).

**`ProxyStatus`**
```json
{
  "requested": {
    "socks": 0,
    "pac": 1081,
    "http": -1
  },
  "effective": {
    "socks": 50861,
    "pac": 1081,
    "http": -1
  }
}
```
Because `0` doesn't tell you what port you actually got, `get_ports` and `save_ports` both return two `ProxySettings`, as siblings:
- `requested` is what's configured, sentinels included. It's exactly what `save_ports` takes, so a settings editor should seed from it and send it back. Seeding from `effective` instead would quietly turn "pick a port" into whatever port it happened to get the moment the user saves.
- `effective` is what's actually bound right now: the real port for anything running, `-1` for anything off, never a literal `0`. Use it to show or connect to the live listeners.

The config file stores `requested`, so "off" and "pick a fresh port each time" both survive a restart rather than freezing on a resolved port. It also stores the password, see [Setting the proxy password](#setting-the-proxy-password).

## Local proxies

All three listeners bind to `127.0.0.1` only.

- **`socks`** is a SOCKS5 proxy, and **`http`** is a standard forward HTTP proxy: CONNECT for HTTPS/TCP tunneling, and absolute-URI requests for plain HTTP. `http` is an alternative to `socks` for clients that only support configuring an HTTP proxy.
- When the password (read with `get_proxy_password`, set with `set_proxy_password`) is non-empty, `socks` requires SOCKS5 username/password authentication (RFC 1929) and `http` requires HTTP `Basic` proxy authentication (`Proxy-Authorization`, replying `407 Proxy Authentication Required` otherwise), both with username `"ntails"` and that password. `pac` never requires authentication. RFC 1929 length-prefixes the username and password with a single byte each, so the password is capped at 255 bytes; `set_proxy_password` rejects a longer one with `invalid_password`.
- Both only reach hosts by name under a **connected** tailnet's `domain`, e.g. `server.tailc7714.ts.net`. Anything else is refused: a failed SOCKS5 request, or HTTP `502`. That includes tailnet IP addresses and every non-tailnet host. So neither should be set as a system-wide proxy on its own; use the PAC file for that.
- The name is looked up in that tailnet's own DNS (MagicDNS), never public DNS, so it covers device names as well as anything else the tailnet's DNS serves, such as Headscale `extra_records` and split-DNS routes. A name the tailnet's DNS has no address for is refused the same way, even if the same name exists on the public internet: the server never connects to a different machine that happens to share the name. Clients should therefore hand the proxy the name itself and let it resolve the address (SOCKS5 with remote name resolution, as browsers do for PAC results).
- **`pac`** serves a proxy auto-config file at `http://127.0.0.1:<pac>/proxy.pac`, generated fresh on each request. For every connected tailnet it routes hosts that are subdomains of `<domain>` through whichever of the other two listeners are running: `SOCKS5` first, then the HTTP proxy as `PROXY`. PAC clients that can't use SOCKS5 therefore fall back to HTTP. Everything else goes `DIRECT`, as does every host when both `socks` and `http` are off or no tailnet is connected.

### Saving ports

`save_ports` checks its `args` in this order and reports only the first problem:
1. `invalid_args`, if the keys aren't exactly `socks`, `pac` and `http` with integer values.
2. `invalid_port`, for the first of `socks`, `pac`, `http` that's out of range.
3. `duplicate_port`, for the first pair asking for the same port (`> 0`).

Then it applies the change. Listeners whose setting didn't change keep running
untouched; so does an auto-picked one now asked for the port it already has.
Changed ones are switched to their new ports, and a port may move from one
listener to another in the same save, e.g. swapping `socks` and `pac`. A
requested port that an unchanged listener is actually bound to (e.g. one it
auto-picked) is a `duplicate_port`.

That's all or nothing. The new listeners are bound and the config file written
before any old listener is retired. If a new port can't be bound
(`port_unavailable`) or the file can't be written (`storage_failed`), everything
goes back to how it was, on the exact same ports, nothing is persisted, and the
response is the error. In one rare case it can't: a listener that gave up its
port for another's in the same save, if something outside ntails grabs that port
in the moment between. That listener is then left off, exactly as if it had
failed at startup (see below).

### Setting the proxy password

`set_proxy_password` checks `password` (`invalid_args` if it's missing or not
a string, `invalid_password` if over 255 bytes), writes it to the config file,
and only then applies it to the running `socks` and `http` listeners. Neither
listener rebinds, so there's nothing to roll back if applying it somehow failed
after a successful write; the only failure that can happen is `storage_failed`,
in which case nothing changed.

Its response is `{password}`, the value now in effect. `get_proxy_password`
returns the same shape. A client that caches the password must also call
`get_proxy_password` at startup, since neither `get_ports` nor any event
carries it.

### Startup failures

At launch, each listener starts independently. One whose configured port can't
be bound is left off, and the server sends one `invalid_config` event for each
that failed, before any other line. The others run normally. A failed listener
shows `-1` in `effective` while `requested` still shows its saved port. Treat
that combination (`requested` isn't `-1`, `effective` is `-1`) as "failed to
start" rather than "off"; it holds even if the event was missed.

Nothing retries on its own. A client should show the problem to the user and
retry only when the user asks, by sending `save_ports` with a different port
or the same one once it's free. That retries every listener that failed, even
when the settings sent are unchanged. Its response is the outcome: success with
the new `ProxyStatus`, or the reason it still failed. Because every save retries
failed listeners, a save that only changes another listener also fails while one
is still blocked, with `port_unavailable` naming the blocked listener; a client
should point the user at it.

## Lifecycle

Only one ntailsd runs per user. If another is already running, `ntailsd rpc`
sends a single `fatal` event (`already_running`) and exits with code 1 without
reading stdin.

On startup, the server reconnects every previously known network automatically —
no command is needed to trigger this — *unless* it was left `disconnected` (via
`disconnect_network`) as of the last clean state, in which case it starts up
still `disconnected` and waits for an explicit `connect_network`. Each
reconnecting network's progress streams in via `network_changed` events the same
as a freshly added network's would. Whenever a network needs the user to sign in
without a request having prompted it — at startup, or later because a connected
session expired — the server also sends a `notification`, since the client has
no reason of its own to be watching for it.

The ssh `ProxyCommand` listener also starts at launch; if it can't, that's only
logged to stderr.

`quit` is the clean, cooperative way to stop the server: it responds, then
closes every network's connection and exits. The same shutdown also runs if
stdin simply closes (EOF) without a `quit` ever being sent — e.g. the frontend
crashed, was force-quit, or was killed by a debugger before it could say
goodbye. A frontend's exit, for any reason, closes its end of the stdin pipe, so
the backend never outlives a frontend that disappeared uncleanly; a client can
still send `quit` for an orderly exit it controls, but it's not the only way the
server ever stops.

On Unix, as a second, independent check, the server also polls once a minute
whether its parent process is still the one that launched it (`getppid`); if
it's been reparented (the usual sign the parent died without that pipe closing —
e.g. an orphaned debug-session child), it shuts down the same way. On Windows,
stdin closing is the only signal. A client never sees or controls this.

## Example session

```
-> {"id":1,"cmd":"login_network","args":{"controlUrl":""}}
<- {"type":"event","name":"network_changed","data":{"id":"a1b2","controlUrl":"","domain":"","status":"connecting","loginUrl":""}}
<- {"type":"res","id":1,"ok":true,"data":{"id":"a1b2","controlUrl":"","domain":"","status":"connecting","loginUrl":""}}
<- {"type":"event","name":"network_changed","data":{"id":"a1b2","controlUrl":"","domain":"","status":"waiting for login","loginUrl":"https://login.tailscale.com/..."}}
<- {"type":"event","name":"network_changed","data":{"id":"a1b2","controlUrl":"","domain":"example.ts.net","status":"connected","loginUrl":""}}

-> {"id":2,"cmd":"disconnect_network","args":{"id":"a1b2"}}
<- {"type":"event","name":"network_changed","data":{"id":"a1b2","controlUrl":"","domain":"example.ts.net","status":"disconnected","loginUrl":""}}
<- {"type":"res","id":2,"ok":true}

-> {"id":3,"cmd":"connect_network","args":{"id":"a1b2"}}
<- {"type":"event","name":"network_changed","data":{"id":"a1b2","controlUrl":"","domain":"example.ts.net","status":"connecting","loginUrl":""}}
<- {"type":"res","id":3,"ok":true}
<- {"type":"event","name":"network_changed","data":{"id":"a1b2","controlUrl":"","domain":"example.ts.net","status":"connected","loginUrl":""}}

-> {"id":4,"cmd":"logout_network","args":{"id":"a1b2"}}
<- {"type":"res","id":4,"ok":true}
<- {"type":"event","name":"network_removed","data":{"id":"a1b2"}}

-> {"id":5,"cmd":"quit"}
<- {"type":"res","id":5,"ok":true}
```

Note the first `network_changed` arriving *before* its triggering request's own
response — `login_network` synchronously transitions the network to `connecting`
as part of handling the request, and that status change is reported the instant
it happens rather than being held until the response is written.
