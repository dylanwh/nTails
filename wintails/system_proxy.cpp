#include "system_proxy.h"

#include <wininet.h>

namespace {

constexpr wchar_t kRegKey[] = L"Software\\ntails";
constexpr wchar_t kUseValue[] = L"UseSystemPac";
// The user's own setting from before ntails took over (see ApplySystemPac).
constexpr wchar_t kSavedValue[] = L"SavedSystemProxy";
constexpr wchar_t kSavedFlags[] = L"SavedProxyFlags";
constexpr wchar_t kSavedServer[] = L"SavedProxyServer";
constexpr wchar_t kSavedBypass[] = L"SavedProxyBypass";
constexpr wchar_t kSavedAutoConfigUrl[] = L"SavedProxyAutoConfigUrl";

DWORD ReadDword(HKEY key, const wchar_t* name, DWORD def) {
    DWORD value = 0, size = sizeof(value), type = 0;
    if (RegQueryValueExW(key, name, nullptr, &type, reinterpret_cast<BYTE*>(&value), &size) == ERROR_SUCCESS &&
        type == REG_DWORD) {
        return value;
    }
    return def;
}

std::wstring ReadString(HKEY key, const wchar_t* name) {
    wchar_t buf[2048]{};
    DWORD size = sizeof(buf) - sizeof(wchar_t), type = 0;
    if (RegQueryValueExW(key, name, nullptr, &type, reinterpret_cast<BYTE*>(buf), &size) == ERROR_SUCCESS &&
        type == REG_SZ) {
        return buf;
    }
    return L"";
}

void WriteDword(HKEY key, const wchar_t* name, DWORD value) {
    RegSetValueExW(key, name, 0, REG_DWORD, reinterpret_cast<const BYTE*>(&value), sizeof(value));
}

void WriteString(HKEY key, const wchar_t* name, const std::wstring& value) {
    RegSetValueExW(key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(value.c_str()),
                   static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
}

bool LoadSaved(SystemProxy* out) {
    HKEY key;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kRegKey, 0, KEY_READ, &key) != ERROR_SUCCESS) return false;
    bool saved = ReadDword(key, kSavedValue, 0) != 0;
    if (saved) {
        out->flags = ReadDword(key, kSavedFlags, PROXY_TYPE_DIRECT);
        out->server = ReadString(key, kSavedServer);
        out->bypass = ReadString(key, kSavedBypass);
        out->autoConfigUrl = ReadString(key, kSavedAutoConfigUrl);
    }
    RegCloseKey(key);
    return saved;
}

void StoreSaved(const SystemProxy* p) { // nullptr forgets it
    HKEY key;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, kRegKey, 0, nullptr, 0, KEY_WRITE, nullptr, &key, nullptr) !=
        ERROR_SUCCESS) {
        return;
    }
    if (p) {
        WriteDword(key, kSavedFlags, p->flags);
        WriteString(key, kSavedServer, p->server);
        WriteString(key, kSavedBypass, p->bypass);
        WriteString(key, kSavedAutoConfigUrl, p->autoConfigUrl);
        WriteDword(key, kSavedValue, 1); // last, so a half-written save never counts
    } else {
        RegDeleteValueW(key, kSavedValue);
        RegDeleteValueW(key, kSavedFlags);
        RegDeleteValueW(key, kSavedServer);
        RegDeleteValueW(key, kSavedBypass);
        RegDeleteValueW(key, kSavedAutoConfigUrl);
    }
    RegCloseKey(key);
}

bool SetSystemProxy(const SystemProxy& p) {
    INTERNET_PER_CONN_OPTIONW options[4]{};
    options[0].dwOption = INTERNET_PER_CONN_FLAGS;
    options[0].Value.dwValue = p.flags;
    options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
    options[1].Value.pszValue = const_cast<wchar_t*>(p.server.c_str());
    options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
    options[2].Value.pszValue = const_cast<wchar_t*>(p.bypass.c_str());
    options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
    options[3].Value.pszValue = const_cast<wchar_t*>(p.autoConfigUrl.c_str());

    INTERNET_PER_CONN_OPTION_LISTW list{};
    list.dwSize = sizeof(list);
    list.pszConnection = nullptr; // the LAN connection, which is what Settings shows
    list.dwOptionCount = 4;
    list.pOptions = options;
    if (!InternetSetOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, sizeof(list))) return false;

    // Tell running WinINet apps (and anything listening for the change) to
    // pick it up now rather than on their next restart.
    InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
    InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
    return true;
}

bool SameSetting(const SystemProxy& a, const SystemProxy& b) {
    return a.flags == b.flags && a.autoConfigUrl == b.autoConfigUrl &&
           ((a.flags & PROXY_TYPE_PROXY) == 0 || (a.server == b.server && a.bypass == b.bypass));
}

// Any loopback URL for an ntailsd PAC file, including ones a user set up by
// hand (e.g. "http://localhost:1081/proxy.pac") before this option existed.
bool IsNtailsPacUrl(const std::wstring& url) {
    constexpr wchar_t kSuffix[] = L"/proxy.pac";
    const size_t suffixLen = wcslen(kSuffix);
    if (url.size() <= suffixLen || url.compare(url.size() - suffixLen, suffixLen, kSuffix) != 0) return false;
    for (const wchar_t* prefix : {L"http://127.0.0.1:", L"http://localhost:", L"http://[::1]:"}) {
        const size_t prefixLen = wcslen(prefix);
        if (url.size() > prefixLen + suffixLen && _wcsnicmp(url.c_str(), prefix, prefixLen) == 0) return true;
    }
    return false;
}

} // namespace

bool QuerySystemProxy(SystemProxy* out) {
    INTERNET_PER_CONN_OPTIONW options[4]{};
    // FLAGS_UI is what the Settings app shows; FLAGS can also carry the
    // results of auto-detection. Older systems only know FLAGS.
    options[0].dwOption = INTERNET_PER_CONN_FLAGS_UI;
    options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
    options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
    options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;

    INTERNET_PER_CONN_OPTION_LISTW list{};
    list.dwSize = sizeof(list);
    list.dwOptionCount = 4;
    list.pOptions = options;
    DWORD size = sizeof(list);
    if (!InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, &size)) {
        options[0].dwOption = INTERNET_PER_CONN_FLAGS;
        size = sizeof(list);
        if (!InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, &size)) return false;
    }

    out->flags = options[0].Value.dwValue;
    auto take = [](wchar_t* s) {
        std::wstring v = s ? s : L"";
        if (s) GlobalFree(s); // WinINet allocates these with GlobalAlloc
        return v;
    };
    out->server = take(options[1].Value.pszValue);
    out->bypass = take(options[2].Value.pszValue);
    out->autoConfigUrl = take(options[3].Value.pszValue);
    return true;
}

std::wstring NtailsPacUrl(int port) { return L"http://127.0.0.1:" + std::to_wstring(port) + L"/proxy.pac"; }

bool HasForeignSystemProxy(const SystemProxy& p) {
    if (p.flags & PROXY_TYPE_PROXY) return true;
    if ((p.flags & PROXY_TYPE_AUTO_PROXY_URL) && !p.autoConfigUrl.empty() && !IsNtailsPacUrl(p.autoConfigUrl))
        return true;
    return false;
}

bool LoadUseSystemPac() {
    HKEY key;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kRegKey, 0, KEY_READ, &key) != ERROR_SUCCESS) return false;
    bool on = ReadDword(key, kUseValue, 0) != 0;
    RegCloseKey(key);
    return on;
}

void SaveUseSystemPac(bool on) {
    HKEY key;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, kRegKey, 0, nullptr, 0, KEY_WRITE, nullptr, &key, nullptr) !=
        ERROR_SUCCESS) {
        return;
    }
    WriteDword(key, kUseValue, on ? 1 : 0);
    RegCloseKey(key);
}

void ApplySystemPac(const std::wstring& pacUrl) {
    SystemProxy current;
    if (!QuerySystemProxy(&current)) return;

    SystemProxy saved;
    if (!LoadSaved(&saved)) StoreSaved(&current);

    // Auto-detect (WPAD) is turned off along with it: WinINet tries that
    // first, and a network's WPAD answer would take precedence over ours.
    SystemProxy next;
    next.flags = pacUrl.empty() ? PROXY_TYPE_DIRECT : PROXY_TYPE_DIRECT | PROXY_TYPE_AUTO_PROXY_URL;
    next.autoConfigUrl = pacUrl;
    if (!SameSetting(current, next)) SetSystemProxy(next);
}

void RestoreSystemProxy() {
    SystemProxy saved;
    if (LoadSaved(&saved)) {
        SetSystemProxy(saved);
        StoreSaved(nullptr);
    } else if (LoadUseSystemPac()) {
        // On, but the saved setting is gone: undo only what's still ours.
        // (Never without the preference on -- a PAC URL the user set up by
        // hand looks the same and isn't ours to remove.)
        SystemProxy current;
        if (QuerySystemProxy(&current) && (current.flags & PROXY_TYPE_AUTO_PROXY_URL) &&
            IsNtailsPacUrl(current.autoConfigUrl)) {
            SetSystemProxy(SystemProxy{});
        }
    }
    SaveUseSystemPac(false);
}
