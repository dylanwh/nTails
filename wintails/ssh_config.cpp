#include "ssh_config.h"

#include <windows.h>

#include <fstream>
#include <sstream>

#include "convert.h"

namespace {

constexpr wchar_t kRegKey[] = L"Software\\ntails";
constexpr wchar_t kEnabledValue[] = L"UpdateSshConfig";
constexpr wchar_t kPathValue[] = L"SshConfigPath";

constexpr char kMarkerBegin[] = "# >>> ntails >>>";
constexpr char kMarkerEnd[] = "# <<< ntails <<<";

std::string ReadFileUtf8(const std::wstring& path) {
    // libstdc++ on mingw accepts wchar_t* paths; std::wstring has no
    // conversion, so pass c_str().
    std::ifstream f(path.c_str(), std::ios::binary);
    if (!f) return "";
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

bool WriteFileUtf8(const std::wstring& path, const std::string& content) {
    std::ofstream f(path.c_str(), std::ios::binary | std::ios::trunc);
    if (!f) return false;
    f.write(content.data(), static_cast<std::streamsize>(content.size()));
    return f.good();
}

// CreateDirectoryW doesn't create intermediate directories; walk path's
// parent one component at a time.
void EnsureParentDir(const std::wstring& path) {
    size_t slash = path.find_last_of(L"\\/");
    if (slash == std::wstring::npos) return;
    std::wstring dir = path.substr(0, slash);

    std::wstring partial;
    size_t start = 0;
    while (start <= dir.size()) {
        size_t sep = dir.find_first_of(L"\\/", start);
        partial += dir.substr(start, sep == std::wstring::npos ? std::wstring::npos : sep - start);
        if (!partial.empty() && partial.back() != L':') {
            CreateDirectoryW(partial.c_str(), nullptr); // ignore ERROR_ALREADY_EXISTS
        }
        if (sep == std::wstring::npos) break;
        partial += dir[sep];
        start = sep + 1;
    }
}

} // namespace

SshConfigPref LoadSshConfigPref() {
    SshConfigPref pref;

    HKEY key;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kRegKey, 0, KEY_READ, &key) != ERROR_SUCCESS) {
        return pref;
    }

    DWORD enabled = 0, type = 0, size = sizeof(enabled);
    if (RegQueryValueExW(key, kEnabledValue, nullptr, &type, reinterpret_cast<BYTE*>(&enabled), &size) ==
            ERROR_SUCCESS &&
        type == REG_DWORD) {
        pref.enabled = enabled != 0;
    }

    wchar_t buf[MAX_PATH]{};
    DWORD bufSize = sizeof(buf);
    if (RegQueryValueExW(key, kPathValue, nullptr, &type, reinterpret_cast<BYTE*>(buf), &bufSize) ==
            ERROR_SUCCESS &&
        type == REG_SZ && buf[0] != L'\0') {
        pref.path = buf;
    }

    RegCloseKey(key);
    return pref;
}

void SaveSshConfigPref(const SshConfigPref& pref) {
    HKEY key;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, kRegKey, 0, nullptr, 0, KEY_WRITE, nullptr, &key, nullptr) !=
        ERROR_SUCCESS) {
        return;
    }

    DWORD enabled = pref.enabled ? 1 : 0;
    RegSetValueExW(key, kEnabledValue, 0, REG_DWORD, reinterpret_cast<const BYTE*>(&enabled), sizeof(enabled));

    std::wstring path = pref.path.empty() ? SshConfigPref{}.path : pref.path;
    RegSetValueExW(key, kPathValue, 0, REG_SZ, reinterpret_cast<const BYTE*>(path.c_str()),
                   static_cast<DWORD>((path.size() + 1) * sizeof(wchar_t)));

    RegCloseKey(key);
}

std::wstring ExpandSshConfigPath(const std::wstring& path) {
    bool isHome = path == L"~" || path.rfind(L"~/", 0) == 0 || path.rfind(L"~\\", 0) == 0;
    if (!isHome) return path;

    wchar_t profile[MAX_PATH]{};
    DWORD n = GetEnvironmentVariableW(L"USERPROFILE", profile, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return path;

    std::wstring rest = path.substr(1); // drop leading "~"
    if (!rest.empty() && (rest[0] == L'/' || rest[0] == L'\\')) rest.erase(0, 1);

    std::wstring result = std::wstring(profile) + L"\\" + rest;
    for (auto& c : result) {
        if (c == L'/') c = L'\\';
    }
    return result;
}

std::wstring ResolveNtailsdExePath() {
    wchar_t buf[MAX_PATH]{};
    DWORD n = GetModuleFileNameW(nullptr, buf, MAX_PATH);
    std::wstring self(buf, n);
    size_t slash = self.find_last_of(L"\\/");
    std::wstring dir = slash == std::wstring::npos ? L"" : self.substr(0, slash + 1);
    return dir + L"ntailsd.exe";
}

std::string BuildSshConfigBlock(const std::vector<std::string>& domains, const std::wstring& ntailsdExePath) {
    if (domains.empty()) return "";

    std::string hosts;
    for (size_t i = 0; i < domains.size(); i++) {
        if (i) hosts += " ";
        hosts += "*." + domains[i];
    }

    // Quoted: the installer's default install directory (Program Files) has
    // a space in it, and OpenSSH's ProxyCommand parsing honors quoting.
    std::ostringstream block;
    block << "Host " << hosts << "\n"
          << "    ProxyCommand \"" << WideToUtf8(ntailsdExePath) << "\" connect %h %p\n";
    return block.str();
}

bool WriteSshConfigBlock(const std::wstring& path, const std::string& block) {
    if (block.empty()) return true; // nothing to write yet; not an error

    std::string content = ReadFileUtf8(path);
    std::string marked = std::string(kMarkerBegin) + "\n" + block + kMarkerEnd + "\n";

    size_t start = content.find(kMarkerBegin);
    size_t end = content.find(kMarkerEnd);
    if (start != std::string::npos && end != std::string::npos && end >= start) {
        content = content.substr(0, start) + marked + content.substr(end + sizeof(kMarkerEnd) - 1 + 1);
    } else {
        if (!content.empty() && content.back() != '\n') content += "\n";
        content += marked;
    }

    EnsureParentDir(path);
    return WriteFileUtf8(path, content);
}

bool RemoveSshConfigBlock(const std::wstring& path) {
    std::string content = ReadFileUtf8(path);
    if (content.empty()) return true;

    size_t start = content.find(kMarkerBegin);
    size_t end = content.find(kMarkerEnd);
    if (start == std::string::npos || end == std::string::npos || end < start) return true;

    content = content.substr(0, start) + content.substr(end + sizeof(kMarkerEnd) - 1 + 1);
    return WriteFileUtf8(path, content);
}
