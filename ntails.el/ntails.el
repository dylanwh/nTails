;;; ntails.el --- Client for the ntailsd RPC backend -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dylan Hardison

;; Author: Dylan Hardison <dylanwh@gmail.com>
;; URL: https://github.com/dylanwh/ntails
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (qrencode "1.6"))
;; Keywords: comm, tools, network

;; This file is licensed under the Mozilla Public License, v. 2.0.
;; If a copy of the MPL was not distributed with this file, You can
;; obtain one at https://mozilla.org/MPL/2.0/.

;;; Commentary:

;; A client for `ntailsd rpc', the stdin/stdout JSON-Lines backend
;; shared by ntails' native per-platform frontends (see
;; docs/rpc-protocol.md in the ntails repository for the wire
;; protocol this talks).  ntailsd itself manages one or more tailnets
;; (Tailscale or self-hosted Headscale) and local SOCKS5/HTTP/PAC
;; proxies onto them; this library starts it as a subprocess, speaks
;; its protocol, and keeps a local cache of known networks.
;;
;; Requires native JSON (`json-serialize', `json-parse-string'): Emacs
;; 27+ built with libjansson, or Emacs 30+.
;;
;; Usage: M-x ntails-network-list starts ntailsd if needed and opens
;; a `tabulated-list-mode' buffer of known tailnets.  From there:
;;
;;   RET  connect, disconnect, or show a pending sign-in
;;   c/d  connect / disconnect explicitly
;;   D    log out of and forget the network at point (confirms first)
;;   a    log in to a new tailnet (prompts for a Headscale URL, or
;;        leave it empty for tailscale.com)
;;   w    copy the network's domain to the kill ring
;;   s    set the local SOCKS5/HTTP/PAC ports
;;   g    refresh; n/p move; S sorts a column; q buries the buffer
;;
;; Signing in opens a buffer with the sign-in URL and, when the
;; `qrencode' package (GNU ELPA) is loaded, a QR code to scan from a
;; phone.  There, o opens the URL in a browser, w copies it, q closes.
;; The buffer closes itself once the tailnet connects.
;;
;; Evil users: configure these modes as for `proced-mode' or
;; `package-menu-mode'.
;;
;; M-x ntails-write-ssh-config prompts for a file and writes or updates
;; a block there routing every known tailnet's domain through `ntailsd
;; connect' as ssh's ProxyCommand, so `ssh host.tailnet.ts.net' works.
;;
;; The ntails-* functions and hooks are usable on their own for other
;; frontends.

;;; Code:

(require 'cl-lib)
(require 'pcase)
(require 'seq)
(require 'tabulated-list)
(require 'qrencode nil t)

(declare-function qrencode "qrencode" (s &optional mode errcorr return-raw))
(declare-function qrencode-format "qrencode" (qr))

(defgroup ntails nil
  "Client for the ntailsd RPC backend."
  :group 'tools)

(defcustom ntails-executable "ntailsd"
  "Path to the ntailsd executable.
Passed as the program for `make-process', so a bare name (the
default) is resolved against the variable `exec-path' the same as
any other subprocess Emacs starts."
  :type 'string
  :group 'ntails)

(defvar ntails-network-changed-hook nil
  "Hook run when a network's status, domain, or login URL changes.
Each function is called with one argument, the network's alist
data (the same shape as a `network_changed' event's data in
docs/rpc-protocol.md).")

(defvar ntails-network-removed-hook nil
  "Hook run when a network is logged out of.
Each function is called with one argument, the removed network's id.")

(defvar ntails-notification-hook nil
  "Hook run for a `notification' event.
A network needs sign-in without any request prompting it.  Each
function is called with two arguments, TITLE and BODY.")

(defvar ntails--process nil
  "The ntailsd rpc subprocess, or nil if not running.")

(defvar ntails--request-id 0
  "Last request id sent; each `ntails-request' call increments this.")

(defvar ntails--callbacks (make-hash-table :test 'eql)
  "Pending request callbacks, keyed by request id.")

(defvar ntails--networks (make-hash-table :test 'equal)
  "Cache of known networks, keyed by network id.
Each value is an alist shaped like a `network_changed' event's
data.")

(defvar ntails--settings nil
  "Cached `requested' ports from the last `get_settings'/`save_settings'.
An alist with `socks', `pac', and `http' keys, or nil before the first
response.")

(defvar ntails--output-buffer nil
  "Internal buffer accumulating not-yet-newline-terminated stdout.")

(defvar ntails--log-buffer nil
  "Buffer ntailsd's own stderr log output is appended to.
See `ntails-show-log'.  stderr carries no protocol data (see
docs/rpc-protocol.md), so this is for diagnostics only.")

;;;###autoload
(defun ntails-start ()
  "Start the ntailsd rpc subprocess.
Signals a `user-error' if it's already running; call `ntails-quit'
first to restart it."
  (interactive)
  (when (process-live-p ntails--process)
    (user-error "Ntailsd is already running"))
  (setq ntails--request-id 0)
  (clrhash ntails--callbacks)
  (clrhash ntails--networks)
  (unless (buffer-live-p ntails--output-buffer)
    (setq ntails--output-buffer (generate-new-buffer " *ntails-output*")))
  (with-current-buffer ntails--output-buffer
    (erase-buffer))
  (unless (buffer-live-p ntails--log-buffer)
    (setq ntails--log-buffer (get-buffer-create "*ntails-log*")))
  (setq ntails--process
        (make-process
         :name "ntails"
         :command (list ntails-executable "rpc")
         :connection-type 'pipe
         :filter #'ntails--process-filter
         :sentinel #'ntails--process-sentinel
         :stderr ntails--log-buffer
         :noquery t)))

(defun ntails--process-sentinel (proc event)
  "Clean up after PROC (ntailsd) exits, logging EVENT."
  (unless (process-live-p proc)
    (when (buffer-live-p ntails--output-buffer)
      (kill-buffer ntails--output-buffer))
    (setq ntails--process nil)
    (clrhash ntails--callbacks)
    (clrhash ntails--networks)
    (message "Ntails: process exited (%s)" (string-trim event))))

(defun ntails--process-filter (_proc string)
  "Buffer STRING and dispatch each complete JSON-Lines message in it."
  (when (buffer-live-p ntails--output-buffer)
    (with-current-buffer ntails--output-buffer
      (save-excursion
        (goto-char (point-max))
        (insert string)
        (goto-char (point-min))
        (while (search-forward "\n" nil t)
          (let ((line (buffer-substring-no-properties (point-min) (point))))
            (delete-region (point-min) (point))
            (condition-case err
                (let ((msg (json-parse-string line :object-type 'alist
                                              :null-object nil
                                              :false-object :json-false)))
                  (ntails--handle-message msg))
              (error (message "Ntails: JSON parse error: %S on line: %s" err line)))))))))

(defun ntails--handle-message (msg)
  "Dispatch one decoded MSG alist: a response to its callback, or an event."
  (let ((type (alist-get 'type msg)))
    (pcase type
      ("res"
       (let* ((id (alist-get 'id msg))
              (cb (gethash id ntails--callbacks)))
         (when cb
           (remhash id ntails--callbacks)
           (funcall cb msg))))
      ("event"
       (ntails--handle-event (alist-get 'name msg) (alist-get 'data msg)))
      (_ (message "Ntails: unknown message type: %s" type)))))

(defun ntails--handle-event (name data)
  "Handle one server-initiated event NAME with its DATA alist."
  (pcase name
    ("network_changed"
     (let ((id (alist-get 'id data)))
       (puthash id data ntails--networks)
       (message "Ntails: network %s status is now %s"
                (let ((domain (alist-get 'domain data)))
                  (if (or (null domain) (string-empty-p domain)) id domain))
                (alist-get 'status data))
       (ntails--login-sync data)
       (run-hook-with-args 'ntails-network-changed-hook data)))
    ("network_removed"
     (let ((id (alist-get 'id data)))
       (remhash id ntails--networks)
       (ntails--login-close id)
       (run-hook-with-args 'ntails-network-removed-hook id)))
    ("notification"
     (let ((title (alist-get 'title data))
           (body (alist-get 'body data)))
       (message "Ntails: %s - %s" title body)
       (run-hook-with-args 'ntails-notification-hook title body)))
    ("invalid_config"
     (display-warning 'ntails (concat (ntails--describe-error data)
                                      " That listener is off until settings are saved again.")))
    ("fatal"
     (display-warning 'ntails (ntails--describe-error data)))
    (_ (message "Ntails: unhandled event: %s" name))))

(defun ntails-request (cmd &optional args callback)
  "Send CMD to ntailsd with optional ARGS alist, returning its request id.
CALLBACK, if given, is called with the full decoded response alist
once it arrives (`ok', `data', and/or `error' keys, per
docs/rpc-protocol.md)."
  (unless (process-live-p ntails--process)
    (user-error "Ntailsd is not running; call `ntails-start' first"))
  (let* ((id (cl-incf ntails--request-id))
         (req `((id . ,id)
                (cmd . ,cmd))))
    (when args
      (push `(args . ,args) req))
    (when callback
      (puthash id callback ntails--callbacks))
    (process-send-string ntails--process
                          (concat (json-serialize req :null-object nil :false-object :json-false) "\n"))
    id))

;;; Commands

(defun ntails-list-networks (&optional callback)
  "Request the full list of known networks, refreshing the local cache.
CALLBACK, if given, is called with the response alist."
  (ntails-request "list_networks" nil
                  (lambda (res)
                    (when (eq (alist-get 'ok res) t)
                      (clrhash ntails--networks)
                      (seq-doseq (net (alist-get 'data res))
                        (puthash (alist-get 'id net) net ntails--networks)))
                    (when callback (funcall callback res)))))

(defun ntails--cache-settings (res)
  "Store RES's `requested' ports in `ntails--settings' if RES is ok."
  (when (eq (alist-get 'ok res) t)
    (setq ntails--settings (alist-get 'requested (alist-get 'data res)))))

(defun ntails-get-settings (&optional callback)
  "Request ntailsd's current proxy settings, refreshing `ntails--settings'.
CALLBACK, if given, is called with the response alist."
  (ntails-request "get_settings" nil
                  (lambda (res)
                    (ntails--cache-settings res)
                    (when callback (funcall callback res)))))

(defun ntails-login-network (control-url &optional callback)
  "Log in to a new tailnet at CONTROL-URL (\"\" for tailscale.com).
CALLBACK, if given, is called with the response alist."
  (ntails-request "login_network" `((controlUrl . ,(or control-url ""))) callback))

(defun ntails-connect-network (id &optional callback)
  "Reconnect the already-known network ID.  CALLBACK gets the response."
  (ntails-request "connect_network" `((id . ,id)) callback))

(defun ntails-disconnect-network (id &optional callback)
  "Disconnect network ID without forgetting it.  CALLBACK gets the response."
  (ntails-request "disconnect_network" `((id . ,id)) callback))

(defun ntails-logout-network (id &optional callback)
  "Log out of and forget network ID.  CALLBACK gets the response."
  (ntails-request "logout_network" `((id . ,id)) callback))

(defun ntails-save-settings (socks-port pac-port http-port &optional callback)
  "Set ntailsd's local SOCKS5/PAC/HTTP ports to SOCKS-PORT/PAC-PORT/HTTP-PORT.
Each is -1 (off), 0 (OS-picked), or 1-65535, per `ProxySettings' in
docs/rpc-protocol.md; `save_settings' requires all three keys.
CALLBACK, if given, is called with the response alist."
  (ntails-request "save_settings"
                  `((socks . ,socks-port)
                    (pac . ,pac-port)
                    (http . ,http-port))
                  (lambda (res)
                    (ntails--cache-settings res)
                    (when callback (funcall callback res)))))

;;;###autoload
(defun ntails-quit ()
  "Ask ntailsd to shut down cleanly.
`ntails--process-sentinel' finishes tearing down local state once
the subprocess actually exits."
  (interactive)
  (ntails-request "quit"))

;;;###autoload
(defun ntails-show-log ()
  "Pop to the buffer collecting ntailsd's own stderr log output."
  (interactive)
  (unless (buffer-live-p ntails--log-buffer)
    (user-error "No ntails log buffer yet; call `ntails-start' first"))
  (pop-to-buffer ntails--log-buffer))

(defconst ntails--ssh-config-marker-begin "# >>> ntails >>>"
  "Start marker for ntails' block in an ssh config file.")

(defconst ntails--ssh-config-marker-end "# <<< ntails <<<"
  "End marker matching `ntails--ssh-config-marker-begin'.")

;;;###autoload
(defun ntails-write-ssh-config (path)
  "Write or update ntails' block in the ssh config file at PATH.
Routes every known tailnet's domain through `ntailsd connect' as
ssh's `ProxyCommand'.  Only the text between the markers is touched;
safe to re-run."
  (interactive (list (read-file-name "Write ntails block to: " "~/.ssh/" nil nil "config")))
  (let* ((path (expand-file-name path))
         (domains (let (ds)
                    (maphash (lambda (_id net)
                               (let ((domain (alist-get 'domain net)))
                                 (when (and domain (not (string-empty-p domain)))
                                   (push domain ds))))
                             ntails--networks)
                    (nreverse ds)))
         (block (format "Host %s\n    ProxyCommand %S connect %%h %%p\n"
                         (mapconcat (lambda (d) (concat "*." d)) domains " ")
                         (or (executable-find ntails-executable) ntails-executable)))
         (marked (concat ntails--ssh-config-marker-begin "\n" block ntails--ssh-config-marker-end "\n"))
         (content (if (file-exists-p path)
                      (with-temp-buffer (insert-file-contents path) (buffer-string))
                    ""))
         start end)
    (when (string-match (regexp-quote ntails--ssh-config-marker-begin) content)
      (setq start (match-beginning 0))
      (when (string-match (regexp-quote ntails--ssh-config-marker-end) content start)
        (setq end (match-end 0))))
    (let ((new-content
           (if (and start end)
               (concat (substring content 0 start) marked (substring content end))
             (concat content
                     (if (or (string-empty-p content) (string-suffix-p "\n" content)) "" "\n")
                     marked))))
      (make-directory (file-name-directory path) t)
      (write-region new-content nil path))
    (message "Ntails: wrote ssh config block to %s" path)))

;;; Sign-in buffer

(defvar ntails--login-buffers (make-hash-table :test 'equal)
  "Sign-in buffers by network id.  Entries may be dead buffers.")

(defvar-local ntails-login--id nil
  "Network id this sign-in buffer belongs to.")

(defvar-local ntails-login--url nil
  "Sign-in URL currently shown, or nil while waiting for one.")

(defvar ntails-login-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "o" #'ntails-login-browse)
    (define-key map "w" #'ntails-login-copy-url)
    map)
  "Keymap for `ntails-login-mode'.
Quit (q) is inherited from `special-mode-map'.")

(define-derived-mode ntails-login-mode special-mode "Ntails-Login"
  "Major mode showing a tailnet's sign-in URL and QR code.
\\{ntails-login-mode-map}"
  ;; The QR code's half-block rows must touch.
  (setq-local line-spacing nil))

(defun ntails-login-browse ()
  "Open this buffer's sign-in URL with `browse-url'."
  (interactive)
  (unless ntails-login--url
    (user-error "No sign-in URL yet"))
  (browse-url ntails-login--url))

(defun ntails-login-copy-url ()
  "Copy this buffer's sign-in URL to the kill ring."
  (interactive)
  (unless ntails-login--url
    (user-error "No sign-in URL yet"))
  (kill-new ntails-login--url)
  (message "Copied %s" ntails-login--url))

(defun ntails--login-render (buf net)
  "Redraw sign-in buffer BUF for NET's current state."
  (with-current-buffer buf
    (let* ((inhibit-read-only t)
           (url (alist-get 'loginUrl net))
           (url (and url (not (string-empty-p url)) url)))
      (setq ntails-login--url url)
      (erase-buffer)
      (insert (format "Sign in to %s\n\n" (ntails--network-display-name net)))
      (cond
       (url
        (insert-text-button url
                            'action (lambda (_) (browse-url url))
                            'follow-link t
                            'help-echo "Open in browser")
        (insert "\n\n")
        (if (fboundp 'qrencode)
            (insert (propertize (qrencode-format (qrencode url nil nil 'return-raw))
                                'face 'qrencode-face))
          (insert "Install the qrencode package (GNU ELPA) for a QR code.\n"))
        (insert "\no: open in browser   w: copy URL   q: close\n"))
       (t
        (insert (ntails--network-status-title net) "\n")))
      (goto-char (point-min)))))

(defun ntails--login-show (id)
  "Show the sign-in buffer for network ID, creating it if needed."
  (let ((buf (gethash id ntails--login-buffers)))
    (unless (buffer-live-p buf)
      (setq buf (generate-new-buffer "*ntails-login*"))
      (with-current-buffer buf
        (ntails-login-mode)
        (setq ntails-login--id id))
      (puthash id buf ntails--login-buffers))
    (ntails--login-render buf (or (gethash id ntails--networks) `((id . ,id))))
    (pop-to-buffer buf)))

(defun ntails--login-close (id)
  "Close network ID's sign-in buffer, if one is open."
  (let ((buf (gethash id ntails--login-buffers)))
    (remhash id ntails--login-buffers)
    (when (buffer-live-p buf)
      (let ((win (get-buffer-window buf t)))
        (if win (quit-window t win) (kill-buffer buf))))))

(defun ntails--login-sync (net)
  "Update NET's sign-in buffer, if one is open: redraw, or close once connected."
  (let* ((id (alist-get 'id net))
         (buf (gethash id ntails--login-buffers)))
    (when (buffer-live-p buf)
      (if (equal (alist-get 'status net) "connected")
          (progn
            (message "Ntails: signed in to %s" (ntails--network-display-name net))
            (ntails--login-close id))
        (ntails--login-render buf net)))))

;;; Network list UI

(defconst ntails--network-list-buffer-name "*ntails-networks*"
  "Name of the buffer `ntails-network-list' shows.")

(defun ntails--network-display-name (net)
  "Mirror Network.DisplayName (ntailsd's backend/network.go) for NET."
  (let ((domain (alist-get 'domain net))
        (control-url (alist-get 'controlUrl net)))
    (cond
     ((and domain (not (string-empty-p domain))) domain)
     ((and control-url (not (string-empty-p control-url))) control-url)
     (t "tailscale.com"))))

(defun ntails--network-status-title (net)
  "Status column text for NET, matching the other ntails frontends.
For \"error\", shows the `detail' from NET's `error' field as is."
  (let ((status (alist-get 'status net)))
    (cond
     ((equal status "connected") "Connected")
     ((equal status "disconnected") "Disconnected")
     ((equal status "connecting") "Connecting...")
     ((equal status "waiting for login") "Waiting for sign-in")
     ((equal status "error")
      (concat "Error: " (alist-get 'detail (alist-get 'error net))))
     (t (or status "unknown")))))

(defun ntails--network-needs-login-p (net)
  "Non-nil if NET is waiting on a sign-in URL that has arrived."
  (and (equal (alist-get 'status net) "waiting for login")
       (let ((url (alist-get 'loginUrl net)))
         (and url (not (string-empty-p url))))))

(defun ntails--network-provider (net)
  "Return \"Headscale\" or \"Tailscale\" for NET, by whether it sets a URL."
  (if (string-empty-p (or (alist-get 'controlUrl net) ""))
      "Tailscale"
    "Headscale"))

(defun ntails--network-list-entries ()
  "Build `tabulated-list-entries' from the local network cache."
  (let (entries)
    (maphash
     (lambda (id net)
       (push (list id (vector (ntails--network-display-name net)
                               (ntails--network-status-title net)
                               (ntails--network-provider net)))
             entries))
     ntails--networks)
    (sort entries (lambda (a b) (string-lessp (aref (cadr a) 0) (aref (cadr b) 0))))))

(defun ntails--network-list-buffer ()
  "Return the live network-list buffer, or nil."
  (get-buffer ntails--network-list-buffer-name))

(defun ntails--network-list-refresh-if-visible (&rest _)
  "Re-print the network-list buffer, if it exists, preserving point.
Hooked onto the changed/removed hooks; a no-op when the buffer
doesn't exist."
  (let ((buf (ntails--network-list-buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (revert-buffer)))))

(add-hook 'ntails-network-changed-hook #'ntails--network-list-refresh-if-visible)
(add-hook 'ntails-network-removed-hook #'ntails--network-list-refresh-if-visible)

(defun ntails--network-list-revert (&optional _ignore-auto _noconfirm)
  "`revert-buffer-function' for `ntails-network-list-mode'."
  (setq tabulated-list-entries (ntails--network-list-entries))
  (tabulated-list-print t))

(defun ntails--network-list-id-at-point ()
  "Return the network id for the row at point.
Signals a `user-error' if point isn't on a network's row."
  (or (tabulated-list-get-id)
      (user-error "No network on this line")))

(defun ntails--network-list-net-at-point ()
  "Return the cached network alist for the row at point."
  (let ((id (ntails--network-list-id-at-point)))
    (or (gethash id ntails--networks)
        (user-error "Unknown network %s" id))))

(defun ntails--listener-name (field)
  "Display name for a `ProxySettings' key FIELD (\"socks\"/\"pac\"/\"http\")."
  (cond
   ((equal field "socks") "SOCKS5 proxy")
   ((equal field "pac") "PAC file")
   ((equal field "http") "HTTP proxy")
   (t "local proxy")))

(defun ntails--describe-error (err)
  "Render ERR (an `Error' alist, docs/rpc-protocol.md) for display.
The wire carries only a code, so the wording lives here.  Unknown
codes fall back to the raw code."
  (let ((code (alist-get 'code err)))
    (cond
     ((equal code "invalid_port")
      (format "The %s port must be between 1 and 65535."
              (ntails--listener-name (alist-get 'field err))))
     ((equal code "duplicate_port")
      (let ((fields (alist-get 'fields err)))
        (format "The %s and %s can't use the same port."
                (ntails--listener-name (aref fields 0))
                (ntails--listener-name (aref fields 1)))))
     ((equal code "port_unavailable")
      (format "The %s port is already in use by another program."
              (ntails--listener-name (alist-get 'field err))))
     ((equal code "storage_failed")
      "Ntails couldn't save its files, so nothing was changed. Check that there's free disk space and try again.")
     ((equal code "network_not_found") "That tailnet no longer exists.")
     ((equal code "invalid_state") "That action isn't available in the tailnet's current state.")
     ((equal code "already_running") "Another ntailsd is already running.")
     ((equal code "invalid_args")
      ;; A bug in this library, but the field narrows it down for a report.
      (format "Something went wrong in ntails.el (invalid_args%s)."
              (if-let* ((field (alist-get 'field err))) (concat ": " field) "")))
     (t
      ;; invalid_request/unknown_command (also this library's own bugs),
      ;; internal, or a code this build doesn't recognize yet: nothing the
      ;; user can act on beyond trying again.
      (format "Something went wrong in ntails (%s)." (or code "unknown error"))))))

(defun ntails--network-list-report-error (res)
  "Show RES's error with `message', unless its `ok' field is t."
  (unless (eq (alist-get 'ok res) t)
    (message "Ntails: %s" (ntails--describe-error (alist-get 'error res)))))

(defun ntails-network-list-connect ()
  "Connect the network at point."
  (interactive)
  (ntails-connect-network (ntails--network-list-id-at-point)
                           #'ntails--network-list-report-error))

(defun ntails-network-list-disconnect ()
  "Disconnect the network at point."
  (interactive)
  (ntails-disconnect-network (ntails--network-list-id-at-point)
                              #'ntails--network-list-report-error))

(defun ntails-network-list-primary-action ()
  "Primary action for the network at point.
Shows its sign-in buffer if a sign-in URL is waiting, connects if
disconnected, else disconnects.  The `network_changed' event
refreshes the buffer."
  (interactive)
  (let ((net (ntails--network-list-net-at-point))
        (id (ntails--network-list-id-at-point)))
    (cond
     ((ntails--network-needs-login-p net)
      (ntails--login-show id))
     ((member (alist-get 'status net) '("disconnected" "error"))
      (ntails-connect-network id #'ntails--network-list-report-error))
     (t
      (ntails-disconnect-network id #'ntails--network-list-report-error)))))

(defun ntails-network-list-logout ()
  "Log out of and forget the network at point, after confirming.
Unlike disconnect, there is no reconnecting afterward."
  (interactive)
  (let* ((net (ntails--network-list-net-at-point))
         (id (ntails--network-list-id-at-point))
         (name (ntails--network-display-name net)))
    (when (y-or-n-p (format "Log out of %s and forget it? " name))
      (ntails-logout-network id #'ntails--network-list-report-error))))

(defun ntails-network-list-add (control-url)
  "Log in to a new tailnet at CONTROL-URL (empty for tailscale.com).
Opens its sign-in buffer, which fills in once the URL arrives."
  (interactive (list (read-string "Headscale control URL (empty for tailscale.com): ")))
  (ntails-login-network control-url
                        (lambda (res)
                          (ntails--network-list-report-error res)
                          (when (eq (alist-get 'ok res) t)
                            (let ((net (alist-get 'data res)))
                              (puthash (alist-get 'id net) net ntails--networks)
                              (ntails--login-show (alist-get 'id net)))))))

(defun ntails-network-list-copy-domain ()
  "Copy the domain (or control URL, for Headscale) of the network at point."
  (interactive)
  (let ((text (ntails--network-display-name (ntails--network-list-net-at-point))))
    (kill-new text)
    (message "Copied %s" text)))

(defun ntails-network-list-set-proxy-ports (socks pac http)
  "Set ntailsd's local SOCKS5/PAC/HTTP ports to SOCKS/PAC/HTTP.
Any of the three may be `-1' (off) or `0' (let the OS pick)."
  (interactive
   (let ((current (lambda (key default)
                    (or (alist-get key ntails--settings) default))))
     (list (read-number "SOCKS5 port (-1 off, 0 auto): " (funcall current 'socks 1080))
           (read-number "PAC port (-1 off, 0 auto): " (funcall current 'pac 1081))
           (read-number "HTTP proxy port (-1 off, 0 auto): " (funcall current 'http 1082)))))
  (ntails-save-settings socks pac http #'ntails--network-list-report-error))

(defvar ntails-network-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ntails-network-list-primary-action)
    (define-key map "c" #'ntails-network-list-connect)
    (define-key map "d" #'ntails-network-list-disconnect)
    (define-key map "D" #'ntails-network-list-logout)
    (define-key map "a" #'ntails-network-list-add)
    (define-key map "w" #'ntails-network-list-copy-domain)
    (define-key map "s" #'ntails-network-list-set-proxy-ports)
    map)
  "Keymap for `ntails-network-list-mode'.
Movement (n/p), refresh (g), sort (S), and quit (q) are inherited
from `tabulated-list-mode-map'.")

(define-derived-mode ntails-network-list-mode tabulated-list-mode "Ntails-Networks"
  "Major mode listing ntailsd's known tailnets.
\\{ntails-network-list-mode-map}"
  (setq tabulated-list-format
        [("Tailnet" 30 t)
         ("Status" 22 t)
         ("Provider" 10 t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key '("Tailnet" . nil))
  (setq revert-buffer-function #'ntails--network-list-revert)
  (tabulated-list-init-header))

;;;###autoload
(defun ntails-network-list ()
  "Show ntailsd's known tailnets, starting the backend first if needed.
\\<ntails-network-list-mode-map>Use \\[ntails-network-list-primary-action]
to connect, disconnect, or open a sign-in URL; \\[ntails-network-list-add]
to log in to a new one; \\[ntails-network-list-logout] to log out of and
forget one."
  (interactive)
  (unless (process-live-p ntails--process)
    (ntails-start))
  (let ((buf (get-buffer-create ntails--network-list-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'ntails-network-list-mode)
        (ntails-network-list-mode))
      (ntails-list-networks (lambda (_res) (ntails--network-list-refresh-if-visible)))
      (ntails-get-settings))
    (pop-to-buffer buf)))

(provide 'ntails)
;;; ntails.el ends here
