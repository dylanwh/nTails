#pragma once

#include <string>
#include <vector>

// Writes the ntails ProxyCommand block into the user's ssh config.
// Client-side so the OS can gate access to a dotfile.

// The "update ssh config" toggle and path, persisted in HKCU\Software\ntails.
struct SshConfigPref {
    bool enabled = false;
    std::wstring path = L"~/.ssh/config";
};

SshConfigPref LoadSshConfigPref();
void SaveSshConfigPref(const SshConfigPref& pref);

// Resolves a leading "~" (as typed in the settings dialog) against
// %USERPROFILE%; any other path is returned unchanged.
std::wstring ExpandSshConfigPath(const std::wstring& path);

// wintails.exe's own installed directory is where the installer also places
// ntailsd.exe (see installer/Product.wxs) -- resolve that path for the
// ProxyCommand line rather than relying on PATH, which the running process
// may not share with ssh's.
std::wstring ResolveNtailsdExePath();

// Builds "Host *.<domain>...\n    ProxyCommand "<exe>" connect %h %p\n" from
// the tailnets' known MagicDNS suffixes. Returns "" if domains is empty
// (nothing to write yet) -- not an error.
std::string BuildSshConfigBlock(const std::vector<std::string>& domains, const std::wstring& ntailsdExePath);

// Upserts the "# >>> ntails >>>" / "# <<< ntails <<<" block into the file at
// path, which may be shared with the user's own config. Succeeds as a no-op
// if block is "".
bool WriteSshConfigBlock(const std::wstring& path, const std::string& block);

// Undoes WriteSshConfigBlock's write at path. A no-op if there's no marked
// block there.
bool RemoveSshConfigBlock(const std::wstring& path);
