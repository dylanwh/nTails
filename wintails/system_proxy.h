#pragma once

#include <windows.h>
#include <wininet.h>

#include <string>

// Pointing Windows' own proxy setting ("Use setup script" in Settings ->
// Network & Internet -> Proxy) at ntailsd's PAC file, so Edge, Chrome,
// Firefox (by default) and other apps that follow the system setting reach
// tailnet hosts with no manual setup. This is the current user's setting,
// changed through WinINet's per-connection options -- the same thing the
// Settings app changes -- so it needs no admin rights.
//
// The user's previous setting is saved (in HKCU\Software\ntails) the first
// time this takes over, and restored when they turn it off or uninstall.

// Windows' proxy configuration for the current user's LAN connection.
struct SystemProxy {
    DWORD flags = PROXY_TYPE_DIRECT; // PROXY_TYPE_* bits
    std::wstring server;             // used with PROXY_TYPE_PROXY
    std::wstring bypass;
    std::wstring autoConfigUrl;      // used with PROXY_TYPE_AUTO_PROXY_URL
};

bool QuerySystemProxy(SystemProxy* out);

// The PAC URL ntailsd serves on port, as Windows should be pointed at.
std::wstring NtailsPacUrl(int port);

// Whether p is set up some other way than "no proxy" or ntails' own PAC
// file -- i.e. turning on "Use for Windows" would replace something.
bool HasForeignSystemProxy(const SystemProxy& p);

// The "Use for Windows" preference.
bool LoadUseSystemPac();
void SaveUseSystemPac(bool on);

// Points Windows at pacUrl, first saving the current setting if nothing is
// saved yet. An empty pacUrl (ntailsd's PAC listener is off or failed to
// start) sets "no proxy" instead, rather than a script nothing serves; the
// saved setting stays saved. A no-op if Windows is already set that way.
void ApplySystemPac(const std::wstring& pacUrl);

// Puts back the setting saved by ApplySystemPac and forgets it. With
// nothing saved but the preference on, only undoes a setting that still
// points at ntails' PAC file (to "no proxy"); with the preference off,
// changes nothing. Also turns the preference off.
void RestoreSystemProxy();
