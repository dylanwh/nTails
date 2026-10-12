#pragma once

#include <windows.h>

#include <functional>
#include <string>

// socks/pac/http each also accept the two sentinels docs/rpc-protocol.md
// defines: -1 turns that listener off, 0 lets ntailsd pick a free port
// itself. The dialog never shows them as numbers: -1 is an unticked
// checkbox on that row, 0 a blank port field.
//
// socks/pac/http are ntailsd's requested ports (what save_settings takes
// and what the dialog edits); effective is what's actually bound, shown only
// as each listener's read-only, copyable URL.
struct ProxyPorts {
    int socks = -1;
    int pac = -1;
    int http = -1;
};

struct SettingsValues {
    int socks = 1080;
    int pac = 1081;
    int http = 1082;
    ProxyPorts effective;
    bool useSystemPac = false; // "Use for Windows": see system_proxy.h
    bool updateSshConfig = false;
    std::string sshConfigPath = "~/.ssh/config";
};

// Modal settings dialog: an on/off checkbox and port for each of
// SOCKS5/PAC/HTTP, an "update ssh config" checkbox, and its path.
//
// Saving is an RPC round trip. Save calls trySave(values, done); done(true)
// closes the dialog, done(false, err) shows err and keeps it open. The modal
// loop keeps pumping, so the response arrives normally.
//
// Returns true if settings were saved, false if the user cancelled.
bool ShowSettingsDialog(
    HWND owner, HINSTANCE instance, const SettingsValues& current,
    std::function<void(const SettingsValues&, std::function<void(bool ok, const std::string& error)>)> trySave);
