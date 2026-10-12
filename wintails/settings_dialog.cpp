#include "settings_dialog.h"

#include <commctrl.h>
#include <commdlg.h>
#include <windowsx.h>

#include <cerrno>
#include <climits>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "convert.h"
#include "modal.h"
#include "ssh_config.h"
#include "system_proxy.h"

namespace {

constexpr int kClientWidth = 560;
constexpr int kClientHeight = 306;

constexpr int kSshCheckId = 403;
constexpr int kSshPathEditId = 404;
constexpr int kSaveBtnId = 405;
constexpr int kCancelBtnId = 406;
constexpr int kSshBrowseBtnId = 407;
constexpr int kSystemPacCheckId = 408;
// Port rows: checkbox kPortCheckBaseId + i, edit kPortEditBaseId + i, copy
// button kPortCopyBaseId + i.
constexpr int kPortCheckBaseId = 410;
constexpr int kPortEditBaseId = 420;
constexpr int kPortCopyBaseId = 430;

constexpr int kSocksRow = 0;
constexpr int kPacRow = 1;
constexpr int kHttpRow = 2;
constexpr int kPortRows = 3;

// PAC comes first on screen: with "Use for Windows" it's the one most users
// actually set up. (The row indexes above stay in ProxySettings order.)
constexpr int kRowDisplayOrder[kPortRows] = {kPacRow, kSocksRow, kHttpRow};

// What the edit shows for a listener that's off, so ticking it back on
// starts from the familiar port rather than an empty (auto) field.
constexpr int kDefaultPorts[kPortRows] = {1080, 1081, 1082};

// Per listener: on/off checkbox, port field (blank = 0 = auto; unticked =
// -1), read-only live URL, Copy button.
struct PortRow {
    HWND check = nullptr;
    HWND edit = nullptr;
    HWND url = nullptr;
    HWND copyBtn = nullptr;
};

// How a client reaches each listener, given its effective port.
std::wstring ListenerUrl(int row, int port) {
    std::wstring hostPort = L"127.0.0.1:" + std::to_wstring(port);
    switch (row) {
        case kSocksRow: return L"socks5://" + hostPort;
        case kPacRow: return L"http://" + hostPort + L"/proxy.pac";
        default: return L"http://" + hostPort;
    }
}

// Off disables the port and the URL of a listener about to stop.
void SetRowEnabled(const PortRow& row, bool on) {
    EnableWindow(row.edit, on);
    bool hasUrl = GetWindowTextLengthW(row.url) > 0;
    EnableWindow(row.url, on && hasUrl);
    EnableWindow(row.copyBtn, on && hasUrl);
}

struct State {
    HWND hwnd = nullptr;
    PortRow rows[kPortRows];
    HWND systemPacCheck = nullptr;
    HWND sshCheck = nullptr;
    HWND sshPathEdit = nullptr;
    HWND sshBrowseBtn = nullptr;
    HWND saveBtn = nullptr;

    SettingsValues current;
    bool done = false;
    bool succeeded = false;

    std::function<void(const SettingsValues&, std::function<void(bool, const std::string&)>)> trySave;
};

// GetOpenFileNameW instead of Save because we're updating a marked block.
std::wstring BrowseForSshConfigPath(HWND owner, const std::wstring& current) {
    wchar_t buf[MAX_PATH]{};
    std::wstring expanded = ExpandSshConfigPath(current);
    wcsncpy_s(buf, expanded.c_str(), MAX_PATH - 1);

    OPENFILENAMEW ofn{};
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = owner;
    ofn.lpstrFile = buf;
    ofn.nMaxFile = MAX_PATH;
    ofn.lpstrFilter = L"ssh config\0config\0All files\0*.*\0\0";
    ofn.lpstrTitle = L"Choose ssh config file";
    // Not OFN_FILEMUSTEXIST: the file is created on first write if it's not
    // there yet. The containing folder (~\.ssh) is expected to exist.
    ofn.Flags = OFN_PATHMUSTEXIST | OFN_NOVALIDATE | OFN_HIDEREADONLY;

    if (GetOpenFileNameW(&ofn)) {
        return std::wstring(buf);
    }
    return L"";
}

// A row as the wire protocol's port value: -1 when unticked, 0 for a blank
// field, otherwise the number typed. Strict, unlike _wtoi: trailing junk
// ("abc", "1080x") fails rather than quietly parsing as something else.
bool ReadPort(const PortRow& row, int* out) {
    if (Button_GetCheck(row.check) != BST_CHECKED) {
        *out = -1;
        return true;
    }
    wchar_t buf[16]{};
    GetWindowTextW(row.edit, buf, 16);
    const wchar_t* start = buf;
    while (*start == L' ') ++start;
    if (*start == L'\0') {
        *out = 0;
        return true;
    }
    wchar_t* end = nullptr;
    errno = 0;
    long v = wcstol(start, &end, 10);
    while (*end == L' ') ++end;
    if (end == start || *end != L'\0' || errno == ERANGE || v < 0 || v > 65535) return false;
    *out = static_cast<int>(v);
    return true;
}

std::string GetEditUtf8(HWND edit) {
    int len = GetWindowTextLengthW(edit);
    std::vector<wchar_t> buf(len + 1);
    GetWindowTextW(edit, buf.data(), len + 1);
    return WideToUtf8(std::wstring(buf.data(), len));
}

void OnSaveClicked(State* state) {
    int socks = 0, pac = 0, http = 0;
    if (!ReadPort(state->rows[kSocksRow], &socks) || !ReadPort(state->rows[kPacRow], &pac) ||
        !ReadPort(state->rows[kHttpRow], &http)) {
        MessageBoxW(state->hwnd, L"Ports must be between 1 and 65535, or blank to let winTails pick one.",
                    L"Settings", MB_ICONWARNING);
        return;
    }
    if ((socks > 0 && (socks == pac || socks == http)) || (pac > 0 && pac == http)) {
        MessageBoxW(state->hwnd, L"SOCKS, PAC, and HTTP ports must differ.", L"Settings", MB_ICONWARNING);
        return;
    }

    SettingsValues values;
    values.socks = socks;
    values.pac = pac;
    values.http = http;
    values.updateSshConfig = Button_GetCheck(state->sshCheck) == BST_CHECKED;
    values.sshConfigPath = GetEditUtf8(state->sshPathEdit);
    if (values.sshConfigPath.empty()) values.sshConfigPath = "~/.ssh/config";
    values.useSystemPac = Button_GetCheck(state->systemPacCheck) == BST_CHECKED;

    // Turning "Use for Windows" on replaces whatever Windows uses now; if
    // that's a proxy of the user's own (e.g. from work), say so first.
    SystemProxy existing;
    if (values.useSystemPac && !state->current.useSystemPac && QuerySystemProxy(&existing) &&
        HasForeignSystemProxy(existing)) {
        int answer = MessageBoxW(state->hwnd,
                                 L"Windows is already set to use a proxy. Replace it with winTails' PAC file?\n\n"
                                 L"winTails will put your current setting back if you turn \"Use for Windows\" off.",
                                 L"Settings", MB_ICONQUESTION | MB_YESNO);
        if (answer != IDYES) {
            Button_SetCheck(state->systemPacCheck, BST_UNCHECKED);
            return;
        }
    }

    EnableWindow(state->saveBtn, FALSE);
    state->trySave(values, [state](bool ok, const std::string& error) {
        if (ok) {
            state->succeeded = true;
            state->done = true;
            return;
        }
        EnableWindow(state->saveBtn, TRUE);
        MessageBoxW(state->hwnd, Utf8ToWide(error).c_str(), L"Settings", MB_ICONERROR);
    });
}

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    auto* state = reinterpret_cast<State*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    switch (msg) {
        case WM_NCCREATE:
            SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                               reinterpret_cast<LONG_PTR>(reinterpret_cast<CREATESTRUCTW*>(lParam)->lpCreateParams));
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        case WM_CREATE: {
            state = reinterpret_cast<State*>(reinterpret_cast<CREATESTRUCTW*>(lParam)->lpCreateParams);
            HINSTANCE inst = reinterpret_cast<CREATESTRUCTW*>(lParam)->hInstance;
            const auto& cur = state->current;

            const wchar_t* labels[kPortRows] = {L"SOCKS5 proxy", L"PAC file", L"HTTP proxy"};
            const int requested[kPortRows] = {cur.socks, cur.pac, cur.http};
            const int effective[kPortRows] = {cur.effective.socks, cur.effective.pac, cur.effective.http};
            int y = 16;
            for (int i : kRowDisplayOrder) { // created in display order, which is also the Tab order
                const int rowY = y;
                y += 36;
                const bool on = requested[i] != -1;
                // Off: show the default so ticking it back on is one click.
                // Auto (0): blank. Otherwise the configured port.
                std::wstring text = !on ? std::to_wstring(kDefaultPorts[i])
                                        : requested[i] == 0 ? L"" : std::to_wstring(requested[i]);

                PortRow& row = state->rows[i];
                row.check = CreateWindowExW(0, L"BUTTON", labels[i], WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_AUTOCHECKBOX,
                                            16, rowY, 140, 22, hwnd, reinterpret_cast<HMENU>(kPortCheckBaseId + i), inst,
                                            nullptr);
                Button_SetCheck(row.check, on ? BST_CHECKED : BST_UNCHECKED);
                row.edit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", text.c_str(), WS_CHILD | WS_VISIBLE | WS_TABSTOP,
                                           160, rowY, 70, 22, hwnd, reinterpret_cast<HMENU>(kPortEditBaseId + i), inst,
                                           nullptr);
                // Shown while blank (= let ntailsd pick), even with focus.
                SendMessageW(row.edit, EM_SETCUEBANNER, TRUE, reinterpret_cast<LPARAM>(L"auto"));
                // Read-only but still an edit, so the URL can be selected
                // and copied by hand as well as with the button.
                std::wstring url = effective[i] > 0 ? ListenerUrl(i, effective[i]) : L"";
                row.url = CreateWindowExW(0, L"EDIT", url.c_str(), WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_READONLY |
                                          ES_AUTOHSCROLL, 242, rowY + 3, 236, 20, hwnd, nullptr, inst, nullptr);
                row.copyBtn = CreateWindowExW(0, L"BUTTON", L"Copy", WS_CHILD | WS_VISIBLE | WS_TABSTOP, 484, rowY - 1,
                                              60, 24, hwnd, reinterpret_cast<HMENU>(kPortCopyBaseId + i), inst,
                                              nullptr);
                SetRowEnabled(row, on);

                if (i == kPacRow) {
                    // Indented under the PAC row it belongs to, and greyed
                    // out with it.
                    state->systemPacCheck =
                        CreateWindowExW(0, L"BUTTON", L"Use for Windows (sets the system proxy setup script)",
                                        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_AUTOCHECKBOX, 36, rowY + 28, 440, 22,
                                        hwnd, reinterpret_cast<HMENU>(kSystemPacCheckId), inst, nullptr);
                    Button_SetCheck(state->systemPacCheck, cur.useSystemPac ? BST_CHECKED : BST_UNCHECKED);
                    EnableWindow(state->systemPacCheck, on);
                    y += 30;
                }
            }
            CreateWindowExW(0, L"STATIC", L"Leave a port blank to let winTails pick a free one.",
                            WS_CHILD | WS_VISIBLE, 16, y, 528, 20, hwnd, nullptr, inst, nullptr);

            state->sshCheck = CreateWindowExW(0, L"BUTTON", L"Update ssh config",
                                               WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_AUTOCHECKBOX,
                                               16, y + 36, 250, 22, hwnd, reinterpret_cast<HMENU>(kSshCheckId), inst, nullptr);
            Button_SetCheck(state->sshCheck, cur.updateSshConfig ? BST_CHECKED : BST_UNCHECKED);

            state->sshPathEdit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", Utf8ToWide(cur.sshConfigPath).c_str(),
                                                  WS_CHILD | WS_VISIBLE | WS_TABSTOP, 16, y + 63, 436, 24,
                                                  hwnd, reinterpret_cast<HMENU>(kSshPathEditId), inst, nullptr);
            state->sshBrowseBtn = CreateWindowExW(0, L"BUTTON", L"Browse...", WS_CHILD | WS_VISIBLE | WS_TABSTOP,
                                                   460, y + 63, 84, 24, hwnd, reinterpret_cast<HMENU>(kSshBrowseBtnId),
                                                   inst, nullptr);

            state->saveBtn = CreateWindowExW(0, L"BUTTON", L"Save", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON,
                                              376, y + 110, 80, 28, hwnd, reinterpret_cast<HMENU>(kSaveBtnId), inst, nullptr);
            CreateWindowExW(0, L"BUTTON", L"Cancel", WS_CHILD | WS_VISIBLE | WS_TABSTOP,
                             464, y + 110, 80, 28, hwnd, reinterpret_cast<HMENU>(kCancelBtnId), inst, nullptr);
            return 0;
        }
        case WM_COMMAND:
            if (LOWORD(wParam) >= kPortCheckBaseId && LOWORD(wParam) < kPortCheckBaseId + kPortRows &&
                HIWORD(wParam) == BN_CLICKED) {
                const int i = LOWORD(wParam) - kPortCheckBaseId;
                const PortRow& row = state->rows[i];
                const bool on = Button_GetCheck(row.check) == BST_CHECKED;
                SetRowEnabled(row, on);
                if (i == kPacRow) EnableWindow(state->systemPacCheck, on);
            } else if (LOWORD(wParam) >= kPortCopyBaseId && LOWORD(wParam) < kPortCopyBaseId + kPortRows &&
                       HIWORD(wParam) == BN_CLICKED) {
                HWND url = state->rows[LOWORD(wParam) - kPortCopyBaseId].url;
                int len = GetWindowTextLengthW(url);
                std::wstring text(len + 1, L'\0');
                GetWindowTextW(url, text.data(), len + 1);
                text.resize(len);
                CopyTextToClipboard(state->hwnd, text);
            } else if (LOWORD(wParam) == kSaveBtnId && HIWORD(wParam) == BN_CLICKED) {
                OnSaveClicked(state);
            } else if (LOWORD(wParam) == kCancelBtnId && HIWORD(wParam) == BN_CLICKED) {
                state->succeeded = false;
                state->done = true;
            } else if (LOWORD(wParam) == kSshBrowseBtnId && HIWORD(wParam) == BN_CLICKED) {
                std::string pathUtf8 = GetEditUtf8(state->sshPathEdit);
                if (pathUtf8.empty()) pathUtf8 = state->current.sshConfigPath;
                std::wstring chosen = BrowseForSshConfigPath(state->hwnd, Utf8ToWide(pathUtf8));
                if (!chosen.empty()) SetWindowTextW(state->sshPathEdit, chosen.c_str());
            }
            return 0;
        case WM_CLOSE:
            state->succeeded = false;
            state->done = true;
            return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

} // namespace

bool ShowSettingsDialog(
    HWND owner, HINSTANCE instance, const SettingsValues& current,
    std::function<void(const SettingsValues&, std::function<void(bool, const std::string&)>)> trySave) {
    static bool registered = false;
    if (!registered) {
        WNDCLASSW wc{};
        wc.lpfnWndProc = WndProc;
        wc.hInstance = instance;
        wc.lpszClassName = L"WintailsSettings";
        wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_BTNFACE + 1);
        RegisterClassW(&wc);
        registered = true;
    }

    State state;
    state.current = current;
    state.trySave = std::move(trySave);

    RECT rect{0, 0, kClientWidth, kClientHeight};
    AdjustWindowRectEx(&rect, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, FALSE, 0);

    HWND hwnd = CreateWindowExW(WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT, L"WintailsSettings", L"Settings",
                                 WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
                                 CW_USEDEFAULT, CW_USEDEFAULT, rect.right - rect.left, rect.bottom - rect.top,
                                 owner, nullptr, instance, &state);
    state.hwnd = hwnd;
    CenterOverOwner(hwnd, owner);
    RunModalLoop(hwnd, owner, &state.done);
    DestroyWindow(hwnd);
    return state.succeeded;
}
