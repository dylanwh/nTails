// wintails: native Win32 frontend for ntails. Drives `ntailsd.exe rpc` as a
// child process over pipes, speaking the protocol in docs/rpc-protocol.md.
//
// Covers the full tailnet lifecycle (Login/Connect/Disconnect/Logout),
// sign-in (QR/link/copy), settings, a system tray icon with hide-on-close,
// and a status bar echoing ntailsd.exe's own stderr log output.
#include <windows.h>
#include <commctrl.h>
#include <jansson.h>
#include <shellapi.h>
#include <windowsx.h>

#include <memory>
#include <string>
#include <unordered_map>

#include "convert.h"
#include "dialogs.h"
#include "first_run.h"
#include "modal.h"
#include "rpc_client.h"
#include "settings_dialog.h"
#include "signin_dialog.h"
#include "ssh_config.h"
#include "system_proxy.h"

// Posted after a SignInDialog's WM_NCDESTROY. lParam is a heap std::string*
// network id, owned by the message. Deferred because DestroyWindow runs
// WM_NCDESTROY synchronously: erasing the unique_ptr from the close callback
// would destroy the dialog mid-call.
#define WM_APP_DIALOG_CLOSED (WM_APP + 2)

// Posted by Shell_NotifyIcon for clicks/right-clicks on the tray icon.
// wParam is the icon's uID (unused, there's only one); lParam is the
// mouse/keyboard event (WM_LBUTTONUP, WM_RBUTTONUP, etc.).
#define WM_APP_TRAYICON (WM_APP + 3)

// The first-run guide's two steps (first_run.h), posted rather than shown
// inline so neither opens from inside an RPC callback. For
// WM_APP_SHOW_APPS_SETUP, lParam is a heap-allocated std::string* network
// id the handler deletes. (WM_APP + 4 is WM_APP_RPC_STDERR_LINE.)
#define WM_APP_SHOW_WELCOME (WM_APP + 5)
#define WM_APP_SHOW_APPS_SETUP (WM_APP + 6)

namespace {

constexpr int kListViewId = 1001;
constexpr int kSettingsButtonId = 1004;
constexpr int kAddButtonId = 1005;
constexpr int kStatusBarId = 1006;
constexpr int kBottomBarHeight = 44;
constexpr int kSummaryBarHeight = 24;
constexpr int kStatusBarHeight = 22;
constexpr UINT kTrayIconId = 1;
constexpr int kTrayShowMenuCmdId = 3001;
constexpr int kTrayQuitMenuCmdId = 3002;
constexpr int kStatusColumnWidth = 150;
constexpr int kProviderColumnWidth = 90;
constexpr int kConnectMenuCmdId = 2001;
constexpr int kLogoutMenuCmdId = 2002;
constexpr int kSignInMenuCmdId = 2003;
constexpr int kCopyDomainMenuCmdId = 2004;
constexpr int kCopyServerUrlMenuCmdId = 2005;

struct NetworkInfo {
    std::string controlUrl;
    std::string domain;
    std::string status;
    std::string loginUrl;
    // From the Network's "error" object, set only while status is "error"
    // (docs/rpc-protocol.md).
    std::string errorCode;
    std::string errorDetail;
};

std::string JField(json_t *obj, const char *key) {
    const char *v = json_string_value(json_object_get(obj, key));
    return v ? v : "";
}

int JInt(json_t *obj, const char *key, int def) {
    json_t *v = json_object_get(obj, key);
    return v ? static_cast<int>(json_integer_value(v)) : def;
}

// Reads a get_ports/save_ports ProxyStatus ({requested, effective},
// docs/rpc-protocol.md) into s, keeping s's current values for anything
// missing.
void ApplyProxyStatus(json_t *data, SettingsValues *s) {
    json_t *req = json_object_get(data, "requested");
    s->socks = JInt(req, "socks", s->socks);
    s->pac = JInt(req, "pac", s->pac);
    s->http = JInt(req, "http", s->http);
    json_t *eff = json_object_get(data, "effective");
    s->effective.socks = JInt(eff, "socks", s->effective.socks);
    s->effective.pac = JInt(eff, "pac", s->effective.pac);
    s->effective.http = JInt(eff, "http", s->effective.http);
}

// Mirrors Network.DisplayName in backend/network.go.
std::string DisplayName(const std::string &domain,
                        const std::string &controlUrl) {
    if (!domain.empty())
        return domain;
    if (!controlUrl.empty())
        return controlUrl;
    return "tailscale.com";
}

// connect_network is valid from these (from "error" it's a retry); every
// other status takes disconnect_network instead (docs/rpc-protocol.md).
bool CanConnect(const std::string &status) {
    return status == "disconnected" || status == "error";
}

bool NeedsLogin(const NetworkInfo &info) {
    return info.status == "waiting for login" && !info.loginUrl.empty();
}

// Status column text, matching nTails.app's NetworkStatusState.title.
std::wstring StatusTitle(const NetworkInfo &info) {
    const std::string &status = info.status;
    if (status == "connected")
        return L"Connected";
    if (status == "disconnected")
        return L"Disconnected";
    if (status == "connecting")
        return L"Connecting...";
    if (status == "waiting for login")
        return L"Waiting for sign-in";
    if (status == "error") {
        std::wstring what = info.errorCode == "start_failed" ? L"Couldn't start"
                            : info.errorCode == "connect_failed"
                                ? L"Couldn't connect"
                                : L"Error";
        return info.errorDetail.empty()
                   ? what
                   : what + L": " + Utf8ToWide(info.errorDetail);
    }
    return Utf8ToWide(status);
}

// Status colors, matching nTails.app's statusColor: green/connected,
// gray/disconnected, blue/connecting, orange/waiting, red/error.
COLORREF StatusColor(const std::string &status) {
    if (status == "connected")
        return RGB(0, 128, 0);
    if (status == "connecting")
        return RGB(0, 90, 200);
    if (status == "waiting for login")
        return RGB(200, 120, 0);
    if (status == "error")
        return RGB(200, 30, 30);
    return GetSysColor(
        COLOR_GRAYTEXT); // disconnected, or anything unrecognized
}

// ListView has no ListView_GetItemData macro; LVIF_PARAM round-trips
// through ListView_GetItem instead.
LPARAM GetItemParam(HWND listView, int index) {
    LVITEMW item{};
    item.mask = LVIF_PARAM;
    item.iItem = index;
    ListView_GetItem(listView, &item);
    return item.lParam;
}

class MainWindow {
  public:
    bool Create(HINSTANCE instance);
    void Show(int cmdShow) { ShowWindow(hwnd_, cmdShow); }

  private:
    static LRESULT CALLBACK WndProcStatic(HWND hwnd, UINT msg, WPARAM wParam,
                                          LPARAM lParam);
    LRESULT WndProc(UINT msg, WPARAM wParam, LPARAM lParam);

    void OnCreate();
    void OnSize(int width, int height);
    void ResizeListColumns();
    void OnCommand(WPARAM wParam);
    void OnDestroy();

    void AddNetwork(const std::string &controlUrl);
    void OnListDoubleClick(int row);
    void OnListContextMenu(int x, int y);
    void OnAddButtonClicked();
    void PerformPrimaryAction(const std::string &id);
    void ConnectOrDisconnect(const std::string &id);
    void DeleteSelected();
    void ConfirmAndLogout(const std::string &id);
    void OnSettingsClicked();
    void SaveSettings(const SettingsValues &v, bool sendPorts,
                      std::function<void(bool, const std::string &)> onResult);
    void CommitSettings(const SettingsValues &v, json_t *data);
    void ShowWelcome();
    void ShowAppsSetup(const std::string &id);
    void RefreshSettingsCache();
    void SyncSshConfig();
    void SyncSystemPac();
    void TrackNewSignInDialog(const std::string &id);
    void SyncSignInDialog(const std::string &id, const std::string &status,
                          const std::string &loginUrl);
    void ShowSignInDialog(const std::string &id);
    LRESULT OnListCustomDraw(NMLVCUSTOMDRAW *cd);
    void UpdateSummaryLabel();
    void UpdateEmptyState();

    void AddTrayIcon();
    void RemoveTrayIcon();
    void OnTrayIconMessage(LPARAM lParam);
    void ShowTrayBalloon(const std::string &title, const std::string &body);

    void RefreshList(json_t *networks); // full replace
    void UpsertRow(json_t *network);
    void RemoveRow(const std::string &id);
    int FindRow(const std::string &id) const;

    HWND hwnd_ = nullptr;
    HWND listView_ = nullptr;
    HWND summaryLabel_ = nullptr;
    HWND emptyStateLabel_ = nullptr;
    HWND addButton_ = nullptr;
    HWND settingsButton_ = nullptr;
    HWND statusBar_ = nullptr;
    bool trayIconAdded_ = false;
    bool appsSetupPosted_ = false; // at most once per run, even before it's marked seen
    RpcClient rpc_;
    SettingsValues settingsCache_;
    std::unordered_map<std::string, NetworkInfo> networks_;
    std::unordered_map<std::string, std::unique_ptr<SignInDialog>>
        signInDialogs_;
};

LRESULT CALLBACK MainWindow::WndProcStatic(HWND hwnd, UINT msg, WPARAM wParam,
                                           LPARAM lParam) {
    MainWindow *self;
    if (msg == WM_NCCREATE) {
        auto *cs = reinterpret_cast<CREATESTRUCTW *>(lParam);
        self = static_cast<MainWindow *>(cs->lpCreateParams);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                          reinterpret_cast<LONG_PTR>(self));
        self->hwnd_ = hwnd;
    } else {
        self = reinterpret_cast<MainWindow *>(
            GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    }
    if (!self)
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    return self->WndProc(msg, wParam, lParam);
}

LRESULT MainWindow::WndProc(UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_CREATE:
        OnCreate();
        return 0;
    case WM_SIZE:
        OnSize(LOWORD(lParam), HIWORD(lParam));
        return 0;
    case WM_COMMAND:
        OnCommand(wParam);
        return 0;
    case WM_NOTIFY: {
        auto *hdr = reinterpret_cast<NMHDR *>(lParam);
        if (hdr->hwndFrom != listView_)
            break;
        if (hdr->code == NM_CUSTOMDRAW) {
            return OnListCustomDraw(reinterpret_cast<NMLVCUSTOMDRAW *>(lParam));
        }
        if (hdr->code == NM_DBLCLK) {
            OnListDoubleClick(
                reinterpret_cast<NMITEMACTIVATE *>(lParam)->iItem);
        } else if (hdr->code == LVN_KEYDOWN) {
            auto *kd = reinterpret_cast<NMLVKEYDOWN *>(lParam);
            if (kd->wVKey == VK_DELETE)
                DeleteSelected();
        }
        return 0;
    }
    case WM_CTLCOLORSTATIC:
        // Labels default to the grey dialog color, but this window's
        // background is COLOR_WINDOW (white) -- match it, so the empty-state
        // message doesn't sit in a grey box.
        SetBkColor(reinterpret_cast<HDC>(wParam), GetSysColor(COLOR_WINDOW));
        return reinterpret_cast<LRESULT>(GetSysColorBrush(COLOR_WINDOW));
    case WM_CONTEXTMENU:
        if (reinterpret_cast<HWND>(wParam) == listView_) {
            OnListContextMenu(GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
        }
        return 0;
    case WM_APP_RPC_LINE:
        rpc_.HandleLine(reinterpret_cast<std::string *>(lParam));
        return 0;
    case WM_APP_RPC_STDERR_LINE: {
        auto *line = reinterpret_cast<std::string *>(lParam);
        SendMessageW(statusBar_, SB_SETTEXTW, 0,
                     reinterpret_cast<LPARAM>(Utf8ToWide(*line).c_str()));
        delete line;
        return 0;
    }
    case WM_APP_DIALOG_CLOSED: {
        auto *id = reinterpret_cast<std::string *>(lParam);
        signInDialogs_.erase(*id);
        delete id;
        return 0;
    }
    case WM_APP_TRAYICON:
        OnTrayIconMessage(lParam);
        return 0;
    case WM_APP_SHOW_WELCOME:
        ShowWelcome();
        return 0;
    case WM_APP_SHOW_APPS_SETUP: {
        auto *id = reinterpret_cast<std::string *>(lParam);
        ShowAppsSetup(*id);
        delete id;
        return 0;
    }
    case WM_CLOSE:
        // Hide; the app lives in the tray. Tray Quit calls DestroyWindow
        // directly.
        ShowWindow(hwnd_, SW_HIDE);
        return 0;
    case WM_DESTROY:
        OnDestroy();
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd_, msg, wParam, lParam);
}

void MainWindow::OnCreate() {
    summaryLabel_ = CreateWindowExW(
        0, L"STATIC", L"", WS_CHILD | WS_VISIBLE | SS_RIGHT, 0, 4, 0, 16, hwnd_,
        nullptr, GetModuleHandleW(nullptr), nullptr);

    listView_ = CreateWindowExW(
        0, WC_LISTVIEWW, L"", WS_CHILD | WS_VISIBLE | WS_BORDER | LVS_REPORT, 0,
        0, 0, 0, hwnd_, reinterpret_cast<HMENU>(kListViewId),
        GetModuleHandleW(nullptr), nullptr);
    ListView_SetExtendedListViewStyle(listView_,
                                      LVS_EX_FULLROWSELECT | LVS_EX_GRIDLINES);

    LVCOLUMNW col{};
    col.mask = LVCF_TEXT | LVCF_WIDTH;

    std::wstring nameHeader = L"Tailnet";
    col.pszText = nameHeader.data();
    col.cx = 260;
    ListView_InsertColumn(listView_, 0, &col);

    std::wstring statusHeader = L"Status";
    col.pszText = statusHeader.data();
    col.cx = 160;
    ListView_InsertColumn(listView_, 1, &col);

    std::wstring providerHeader = L"Provider";
    col.pszText = providerHeader.data();
    col.cx = kProviderColumnWidth;
    ListView_InsertColumn(listView_, 2, &col);

    // Centered over the list, shown only when there are no tailnets yet: the
    // first-run steps, for anyone who skipped the Welcome dialog.
    emptyStateLabel_ = CreateWindowExW(
        0, L"STATIC",
        L"No tailnets yet. To get started:\n\n"
        L"1. Click Add Tailnet below and sign in to Tailscale or Headscale.\n"
        L"2. In Settings, tick \"Use for Windows\" so your browser and apps "
        L"reach tailnet names.\n"
        L"3. To use ssh with tailnet names, also tick \"Update ssh config\".",
        WS_CHILD | SS_CENTER, 0, 0, 0, 0, hwnd_, nullptr,
        GetModuleHandleW(nullptr), nullptr);

    // Row actions live on the row (double-click, context menu), not on a
    // button whose label changes with the selection.
    addButton_ = CreateWindowExW(0, L"BUTTON", L"Add Tailnet",
                                 WS_CHILD | WS_VISIBLE | WS_TABSTOP, 0, 0, 0, 0,
                                 hwnd_, reinterpret_cast<HMENU>(kAddButtonId),
                                 GetModuleHandleW(nullptr), nullptr);
    settingsButton_ = CreateWindowExW(
        0, L"BUTTON", L"Settings", WS_CHILD | WS_VISIBLE | WS_TABSTOP, 0, 0, 0,
        0, hwnd_, reinterpret_cast<HMENU>(kSettingsButtonId),
        GetModuleHandleW(nullptr), nullptr);

    statusBar_ = CreateWindowExW(
        0, STATUSCLASSNAME, L"", WS_CHILD | WS_VISIBLE | SBARS_SIZEGRIP, 0, 0,
        0, 0, hwnd_, reinterpret_cast<HMENU>(kStatusBarId),
        GetModuleHandleW(nullptr), nullptr);
    ApplyUiFont(hwnd_);

    AddTrayIcon();

    rpc_.SetEventCallback([this](const std::string &name, json_t *data) {
        if (name == "network_changed") {
            UpsertRow(data);
        } else if (name == "network_removed") {
            RemoveRow(JField(data, "id"));
        } else if (name == "notification") {
            // ntailsd's title is "ntails"; the Windows app is winTails.
            ShowTrayBalloon("winTails", JField(data, "body"));
        } else if (name == "invalid_config") {
            // data is an Error object; that one listener stays off until a
            // save_ports succeeds (docs/rpc-protocol.md).
            ShowTrayBalloon("winTails proxy is off",
                            DescribeRpcError(data) +
                                " Open Settings to change it, or save again "
                                "once it's free.");
        } else if (name == "fatal") {
            // ntailsd is exiting; report and quit.
            MessageBoxW(hwnd_, Utf8ToWide(DescribeRpcError(data)).c_str(),
                        L"winTails", MB_ICONERROR);
            DestroyWindow(hwnd_); // bypasses the WM_CLOSE hide-intercept
        }
    });

    UpdateEmptyState(); // starts empty until the first list_networks response
                        // arrives

    if (rpc_.Start(hwnd_, L"ntailsd.exe rpc")) {
        rpc_.Send("list_networks", nullptr,
                  [this](bool ok, json_t *data, const std::string &) {
                      if (ok)
                          RefreshList(data);
                      if (ok && networks_.empty() && !LoadWelcomeSeen())
                          PostMessageW(hwnd_, WM_APP_SHOW_WELCOME, 0, 0);
                  });
        RefreshSettingsCache();
    } else {
        MessageBoxW(hwnd_,
                    L"Couldn't start ntailsd.exe rpc. Is it next to "
                    L"wintails.exe or on PATH?",
                    L"winTails", MB_ICONERROR);
    }
}

void MainWindow::OnSize(int width, int height) {
    if (!listView_)
        return;
    // Let the status bar lay itself out, then use its reported height.
    SendMessageW(statusBar_, WM_SIZE, 0, 0);
    RECT statusRect;
    GetWindowRect(statusBar_, &statusRect);
    int statusBarHeight = statusRect.bottom - statusRect.top;
    if (statusBarHeight <= 0)
        statusBarHeight = kStatusBarHeight;

    int listTop = kSummaryBarHeight;
    int listHeight = height - kBottomBarHeight - statusBarHeight - listTop;
    if (listHeight < 0)
        listHeight = 0;
    MoveWindow(summaryLabel_, 0, 4, width - 12, 16, TRUE);
    MoveWindow(listView_, 0, listTop, width, listHeight, TRUE);
    MoveWindow(emptyStateLabel_, 40, listTop + listHeight / 2 - 60, width - 80,
               120, TRUE);
    MoveWindow(addButton_, 12, listTop + listHeight + 8, 150, 28, TRUE);
    MoveWindow(settingsButton_, width - 92, listTop + listHeight + 8, 80, 28,
               TRUE);
    ResizeListColumns();

    // SS_RIGHT label: shrinking leaves the old text unerased. A full repaint
    // is cheap here.
    InvalidateRect(hwnd_, nullptr, TRUE);
}

// Keeps Status and Provider a fixed width and lets Tailnet fill whatever's
// left, so there's no dead space or horizontal scrollbar as the window
// resizes.
void MainWindow::ResizeListColumns() {
    RECT rect;
    GetClientRect(listView_, &rect);
    int available = rect.right - rect.left;
    if (GetWindowLongPtrW(listView_, GWL_STYLE) & WS_VSCROLL) {
        available -= GetSystemMetrics(SM_CXVSCROLL);
    }
    int nameWidth = available - kStatusColumnWidth - kProviderColumnWidth;
    if (nameWidth < 100)
        nameWidth = 100;
    ListView_SetColumnWidth(listView_, 0, nameWidth);
    ListView_SetColumnWidth(listView_, 1, kStatusColumnWidth);
    ListView_SetColumnWidth(listView_, 2, kProviderColumnWidth);
}

void MainWindow::OnCommand(WPARAM wParam) {
    if (HIWORD(wParam) != BN_CLICKED)
        return;
    if (LOWORD(wParam) == kAddButtonId) {
        OnAddButtonClicked();
    } else if (LOWORD(wParam) == kSettingsButtonId) {
        OnSettingsClicked();
    }
}

void MainWindow::OnSettingsClicked() {
    bool saved = ShowSettingsDialog(
        hwnd_, GetModuleHandleW(nullptr), settingsCache_,
        [this](const SettingsValues &v,
               std::function<void(bool, const std::string &)> onResult) {
            SaveSettings(v, true, std::move(onResult));
        });
    if (saved)
        RefreshSettingsCache();
}

// Saves v: its ports through ntailsd's save_ports when sendPorts (which
// also retries any listener that failed to start), then the wintails-local
// parts (see CommitSettings). onResult gets save_ports' error, if any.
void MainWindow::SaveSettings(
    const SettingsValues &v, bool sendPorts,
    std::function<void(bool, const std::string &)> onResult) {
    if (!sendPorts) {
        CommitSettings(v, nullptr);
        onResult(true, "");
        return;
    }
    json_t *args = json_pack("{s:i, s:i, s:i}", "socks", v.socks, "pac",
                              v.pac, "http", v.http);
    rpc_.Send("save_ports", args,
              [this, v, onResult](bool ok, json_t *data,
                                  const std::string &error) {
                  if (!ok) {
                      onResult(false, error);
                      return;
                  }
                  CommitSettings(v, data);
                  onResult(true, "");
              });
}

// The wintails-local half of a save. data is save_ports' ProxyStatus, or
// null if ports weren't sent.
void MainWindow::CommitSettings(const SettingsValues &v, json_t *data) {
    if (settingsCache_.updateSshConfig &&
        (!v.updateSshConfig ||
         settingsCache_.sshConfigPath != v.sshConfigPath)) {
        RemoveSshConfigBlock(
            ExpandSshConfigPath(Utf8ToWide(settingsCache_.sshConfigPath)));
    }
    const bool wasSystemPac = settingsCache_.useSystemPac;
    settingsCache_ = v;
    if (data)
        ApplyProxyStatus(data, &settingsCache_);

    // "Use for Windows" turned off puts the user's own setting back;
    // otherwise follow the (maybe new) PAC port.
    if (wasSystemPac && !v.useSystemPac) {
        RestoreSystemProxy();
    } else {
        SaveUseSystemPac(v.useSystemPac);
        SyncSystemPac();
    }

    SshConfigPref pref;
    pref.enabled = v.updateSshConfig;
    pref.path = Utf8ToWide(v.sshConfigPath);
    SaveSshConfigPref(pref);

    SyncSshConfig();
}

// The first-run guide's first step: shown once, when there are no tailnets.
void MainWindow::ShowWelcome() {
    SaveWelcomeSeen();
    if (ShowWelcomeDialog(hwnd_, GetModuleHandleW(nullptr)))
        OnAddButtonClicked();
}

// The first-run guide's second step: shown once, when a tailnet (id) first
// connects. Applies the choices the same way Settings would.
void MainWindow::ShowAppsSetup(const std::string &id) {
    SaveAppsSetupSeen();
    auto it = networks_.find(id);

    AppsSetupContext context;
    context.domain = it != networks_.end() ? Utf8ToWide(it->second.domain) : L"";
    context.sshConfigPath = Utf8ToWide(settingsCache_.sshConfigPath);
    // A listener that failed to start: requested, but not running.
    SettingsValues v = settingsCache_;
    struct Listener {
        int *requested;
        int effective;
        const wchar_t *name;
    };
    const Listener listeners[] = {{&v.pac, settingsCache_.effective.pac, L"PAC file"},
                                  {&v.socks, settingsCache_.effective.socks, L"SOCKS5 proxy"},
                                  {&v.http, settingsCache_.effective.http, L"HTTP proxy"}};
    for (const Listener &l : listeners) {
        if (*l.requested != -1 && l.effective == -1)
            context.blocked.push_back(l.name);
    }

    AppsSetupChoice choice;
    choice.updateSshConfig = settingsCache_.updateSshConfig;
    if (!ShowAppsSetupDialog(hwnd_, GetModuleHandleW(nullptr), context, &choice))
        return;

    v.useSystemPac = choice.useSystemPac;
    v.updateSshConfig = choice.updateSshConfig;
    // Only touch ports to move blocked listeners onto free ones; otherwise
    // save_ports would just retry them and fail the same way.
    bool sendPorts = choice.repickPorts && !context.blocked.empty();
    if (sendPorts) {
        for (const Listener &l : listeners) {
            if (*l.requested != -1 && l.effective == -1)
                *l.requested = 0; // let ntailsd pick
        }
    }
    SaveSettings(v, sendPorts, [this](bool ok, const std::string &error) {
        if (!ok)
            MessageBoxW(hwnd_, Utf8ToWide(error).c_str(), L"Set Up Your Apps",
                        MB_ICONERROR);
    });
}

void MainWindow::RefreshSettingsCache() {
    SshConfigPref pref = LoadSshConfigPref();
    settingsCache_.updateSshConfig = pref.enabled;
    settingsCache_.sshConfigPath = WideToUtf8(pref.path);
    settingsCache_.useSystemPac = LoadUseSystemPac();

    rpc_.Send("get_ports", nullptr,
              [this](bool ok, json_t *data, const std::string &) {
                  if (!ok)
                      return;
                  ApplyProxyStatus(data, &settingsCache_);
                  // An auto-picked PAC port changes every launch, and a
                  // PAC listener can fail to start: point Windows at
                  // wherever it actually is now.
                  SyncSystemPac();
                  // Networks may already have arrived (list_networks and
                  // get_ports race) before this local pref was known --
                  // (re)sync now that it is.
                  SyncSshConfig();
              });
}

// Points Windows' proxy setup script at the PAC listener's live URL if "Use
// for Windows" is on (no proxy while that listener is off or failed to
// start); a no-op otherwise. Called whenever the PAC port might have
// changed.
void MainWindow::SyncSystemPac() {
    if (!settingsCache_.useSystemPac)
        return;
    int port = settingsCache_.effective.pac;
    ApplySystemPac(port > 0 ? NtailsPacUrl(port) : L"");
}

// (Re)writes the ssh config block from the currently known tailnets' domains
// if the "update ssh config" toggle is on; a no-op otherwise. Called
// whenever the known networks or the toggle/path might have changed.
void MainWindow::SyncSshConfig() {
    if (!settingsCache_.updateSshConfig)
        return;

    std::vector<std::string> domains;
    for (const auto &[id, info] : networks_) {
        if (!info.domain.empty())
            domains.push_back(info.domain);
    }

    std::string block = BuildSshConfigBlock(domains, ResolveNtailsdExePath());
    WriteSshConfigBlock(
        ExpandSshConfigPath(Utf8ToWide(settingsCache_.sshConfigPath)), block);
}

void MainWindow::OnAddButtonClicked() {
    switch (ChooseNetworkType(hwnd_, GetModuleHandleW(nullptr))) {
    case NetworkTypeChoice::Tailscale:
        AddNetwork("");
        break;
    case NetworkTypeChoice::Headscale: {
        std::wstring url;
        if (PromptForHeadscaleUrl(hwnd_, GetModuleHandleW(nullptr), url)) {
            AddNetwork(WideToUtf8(url));
        }
        break;
    }
    case NetworkTypeChoice::Cancel:
        break;
    }
}

// Primary action, matching nTails.app: Sign In if a login URL is ready,
// Connect if disconnected or failed, else Disconnect (also cancels an
// in-flight attempt). Shared by double-click and the context menu.
void MainWindow::PerformPrimaryAction(const std::string &id) {
    auto it = networks_.find(id);
    if (it == networks_.end())
        return;
    if (NeedsLogin(it->second)) {
        ShowSignInDialog(id);
    } else {
        ConnectOrDisconnect(id);
    }
}

void MainWindow::ConnectOrDisconnect(const std::string &id) {
    auto it = networks_.find(id);
    if (it == networks_.end())
        return;
    const char *cmd = CanConnect(it->second.status) ? "connect_network"
                                                    : "disconnect_network";
    json_t *args = json_pack("{s:s}", "id", id.c_str());
    rpc_.Send(cmd, args, [this](bool ok, json_t *, const std::string &error) {
        if (!ok)
            MessageBoxW(hwnd_, Utf8ToWide(error).c_str(), L"winTails",
                        MB_ICONERROR);
    });
}

// Delete key: same confirmation as the context menu's "Log Out & Remove...".
void MainWindow::DeleteSelected() {
    int row = ListView_GetNextItem(listView_, -1, LVNI_SELECTED);
    if (row < 0)
        return;
    auto *idPtr = reinterpret_cast<std::string *>(GetItemParam(listView_, row));
    if (idPtr)
        ConfirmAndLogout(*idPtr);
}

void MainWindow::AddNetwork(const std::string &controlUrl) {
    json_t *args = json_pack("{s:s}", "controlUrl", controlUrl.c_str());
    rpc_.Send("login_network", args,
              [this](bool ok, json_t *data, const std::string &error) {
                  if (!ok) {
                      MessageBoxW(hwnd_, Utf8ToWide(error).c_str(),
                                  L"Add Tailnet", MB_ICONERROR);
                      return;
                  }
                  UpsertRow(data);
                  std::string id = JField(data, "id");
                  if (!id.empty()) {
                      TrackNewSignInDialog(id);
                      signInDialogs_[id]->SetWaiting();
                  }
              });
}

void MainWindow::TrackNewSignInDialog(const std::string &id) {
    auto dlg = std::make_unique<SignInDialog>();
    HWND owner = hwnd_;
    dlg->SetOnClosed([owner](const std::string &closedId) {
        PostMessageW(owner, WM_APP_DIALOG_CLOSED, 0,
                     reinterpret_cast<LPARAM>(new std::string(closedId)));
    });
    dlg->Create(hwnd_, GetModuleHandleW(nullptr), id);
    signInDialogs_[id] = std::move(dlg);
}

void MainWindow::SyncSignInDialog(const std::string &id,
                                  const std::string &status,
                                  const std::string &loginUrl) {
    auto it = signInDialogs_.find(id);
    if (it == signInDialogs_.end() || !it->second->IsValid())
        return; // not something we're tracking

    if (status == "connected") {
        it->second->Close(); // self-removes from signInDialogs_ via
                             // WM_APP_DIALOG_CLOSED
    } else if (!loginUrl.empty()) {
        it->second->SetUrl(loginUrl);
    } else {
        it->second->SetWaiting();
    }
}

// Opens (or brings up to date, if already open) the sign-in dialog for id,
// if it currently has a login URL ready. Shared by double-click and the
// context menu's "Sign In..." item.
void MainWindow::ShowSignInDialog(const std::string &id) {
    auto infoIt = networks_.find(id);
    if (infoIt == networks_.end() || !NeedsLogin(infoIt->second))
        return;

    auto dlgIt = signInDialogs_.find(id);
    if (dlgIt == signInDialogs_.end() || !dlgIt->second->IsValid()) {
        TrackNewSignInDialog(id);
        dlgIt = signInDialogs_.find(id);
    }
    dlgIt->second->SetUrl(infoIt->second.loginUrl);
}

// Mirrors NetworkRowView's menu in nTails.app. A waiting-for-login row can
// still be disconnected, so Sign In sits beside Disconnect.
void MainWindow::OnListContextMenu(int x, int y) {
    int row;
    if (x == -1 && y == -1) { // triggered via Shift+F10 / the context-menu key
        row = ListView_GetNextItem(listView_, -1, LVNI_SELECTED);
        if (row < 0)
            return;
        RECT r;
        ListView_GetItemRect(listView_, row, &r, LVIR_BOUNDS);
        POINT pt{r.left, r.bottom};
        ClientToScreen(listView_, &pt);
        x = pt.x;
        y = pt.y;
    } else {
        POINT pt{x, y};
        ScreenToClient(listView_, &pt);
        LVHITTESTINFO hit{};
        hit.pt = pt;
        row = ListView_HitTest(listView_, &hit);
        if (row < 0)
            return;
        ListView_SetItemState(listView_, row, LVIS_SELECTED, LVIS_SELECTED);
    }

    auto *idPtr = reinterpret_cast<std::string *>(GetItemParam(listView_, row));
    if (!idPtr)
        return;
    auto infoIt = networks_.find(*idPtr);
    if (infoIt == networks_.end())
        return;
    const NetworkInfo &info = infoIt->second;

    HMENU menu = CreatePopupMenu();
    AppendMenuW(menu, MF_STRING, kConnectMenuCmdId,
                CanConnect(info.status) ? L"Connect" : L"Disconnect");
    if (NeedsLogin(info))
        AppendMenuW(menu, MF_STRING, kSignInMenuCmdId, L"Sign In...");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    if (!info.domain.empty())
        AppendMenuW(menu, MF_STRING, kCopyDomainMenuCmdId, L"Copy Domain");
    if (!info.controlUrl.empty())
        AppendMenuW(menu, MF_STRING, kCopyServerUrlMenuCmdId,
                    L"Copy Server URL");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, kLogoutMenuCmdId, L"Log Out && Remove...");

    int cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, x, y, 0,
                             hwnd_, nullptr);
    DestroyMenu(menu);

    switch (cmd) {
    case kConnectMenuCmdId:
        ConnectOrDisconnect(*idPtr);
        break;
    case kSignInMenuCmdId:
        ShowSignInDialog(*idPtr);
        break;
    case kCopyDomainMenuCmdId:
        CopyTextToClipboard(hwnd_, Utf8ToWide(info.domain));
        break;
    case kCopyServerUrlMenuCmdId:
        CopyTextToClipboard(hwnd_, Utf8ToWide(info.controlUrl));
        break;
    case kLogoutMenuCmdId:
        ConfirmAndLogout(*idPtr);
        break;
    }
}

void MainWindow::ConfirmAndLogout(const std::string &id) {
    auto it = networks_.find(id);
    std::wstring name =
        it != networks_.end()
            ? Utf8ToWide(DisplayName(it->second.domain, it->second.controlUrl))
            : L"this tailnet";
    std::wstring message =
        L"Log out of " + name +
        L"? This tears down the connection, forgets your session with the "
        L"coordination server, and removes this tailnet from winTails.";
    if (MessageBoxW(hwnd_, message.c_str(), L"Log Out of Tailnet",
                    MB_YESNO | MB_ICONWARNING) != IDYES)
        return;

    json_t *args = json_pack("{s:s}", "id", id.c_str());
    rpc_.Send("logout_network", args,
              [this](bool ok, json_t *, const std::string &error) {
                  // Success arrives as network_removed.
                  if (!ok)
                      MessageBoxW(hwnd_, Utf8ToWide(error).c_str(),
                                  L"Log Out of Tailnet", MB_ICONERROR);
              });
}

void MainWindow::OnListDoubleClick(int row) {
    if (row < 0)
        return;
    auto *idPtr = reinterpret_cast<std::string *>(GetItemParam(listView_, row));
    if (idPtr)
        PerformPrimaryAction(*idPtr);
}

void MainWindow::OnDestroy() {
    rpc_.Stop();
    RemoveTrayIcon();
    for (int i = 0; i < ListView_GetItemCount(listView_); i++) {
        delete reinterpret_cast<std::string *>(GetItemParam(listView_, i));
    }
}

void MainWindow::AddTrayIcon() {
    NOTIFYICONDATAW nid{};
    nid.cbSize = sizeof(nid);
    nid.hWnd = hwnd_;
    nid.uID = kTrayIconId;
    nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    nid.uCallbackMessage = WM_APP_TRAYICON;
    // TODO: real icon.
    nid.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    wcsncpy_s(nid.szTip, L"winTails", _TRUNCATE);
    trayIconAdded_ = Shell_NotifyIconW(NIM_ADD, &nid) != FALSE;
}

void MainWindow::RemoveTrayIcon() {
    if (!trayIconAdded_)
        return;
    NOTIFYICONDATAW nid{};
    nid.cbSize = sizeof(nid);
    nid.hWnd = hwnd_;
    nid.uID = kTrayIconId;
    Shell_NotifyIconW(NIM_DELETE, &nid);
    trayIconAdded_ = false;
}

void MainWindow::OnTrayIconMessage(LPARAM lParam) {
    if (lParam == WM_LBUTTONUP || lParam == WM_LBUTTONDBLCLK) {
        if (IsIconic(hwnd_))
            ShowWindow(hwnd_, SW_RESTORE);
        ShowWindow(hwnd_, SW_SHOW);
        SetForegroundWindow(hwnd_);
        return;
    }
    if (lParam != WM_RBUTTONUP && lParam != WM_CONTEXTMENU)
        return;

    POINT pt;
    GetCursorPos(&pt);
    HMENU menu = CreatePopupMenu();
    AppendMenuW(menu, MF_STRING, kTrayShowMenuCmdId, L"Show winTails");
    AppendMenuW(menu, MF_STRING, kTrayQuitMenuCmdId, L"Quit");
    // Without this the menu stays up after a click outside it (KB135788).
    SetForegroundWindow(hwnd_);
    int cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x, pt.y,
                             0, hwnd_, nullptr);
    DestroyMenu(menu);

    if (cmd == kTrayShowMenuCmdId) {
        if (IsIconic(hwnd_))
            ShowWindow(hwnd_, SW_RESTORE);
        ShowWindow(hwnd_, SW_SHOW);
        SetForegroundWindow(hwnd_);
    } else if (cmd == kTrayQuitMenuCmdId) {
        DestroyWindow(hwnd_); // bypasses the WM_CLOSE hide-intercept
    }
}

void MainWindow::ShowTrayBalloon(const std::string &title,
                                 const std::string &body) {
    NOTIFYICONDATAW nid{};
    nid.cbSize = sizeof(nid);
    nid.hWnd = hwnd_;
    nid.uID = kTrayIconId;
    nid.uFlags = NIF_INFO;
    nid.dwInfoFlags = NIIF_INFO;
    wcsncpy_s(nid.szInfoTitle, Utf8ToWide(title).c_str(), _TRUNCATE);
    wcsncpy_s(nid.szInfo, Utf8ToWide(body).c_str(), _TRUNCATE);
    Shell_NotifyIconW(NIM_MODIFY, &nid);
}

int MainWindow::FindRow(const std::string &id) const {
    int count = ListView_GetItemCount(listView_);
    for (int i = 0; i < count; i++) {
        auto *rowId =
            reinterpret_cast<std::string *>(GetItemParam(listView_, i));
        if (rowId && *rowId == id)
            return i;
    }
    return -1;
}

void MainWindow::RefreshList(json_t *networks) {
    for (int i = 0; i < ListView_GetItemCount(listView_); i++) {
        delete reinterpret_cast<std::string *>(GetItemParam(listView_, i));
    }
    ListView_DeleteAllItems(listView_);

    size_t index;
    json_t *n;
    json_array_foreach(networks, index, n) { UpsertRow(n); }
}

void MainWindow::UpsertRow(json_t *network) {
    std::string id = JField(network, "id");
    if (id.empty())
        return;

    json_t *error = json_object_get(network, "error");
    NetworkInfo info{JField(network, "controlUrl"), JField(network, "domain"),
                     JField(network, "status"),     JField(network, "loginUrl"),
                     JField(error, "code"),         JField(error, "detail")};

    std::wstring name = Utf8ToWide(DisplayName(info.domain, info.controlUrl));
    std::wstring status = StatusTitle(info);
    std::wstring provider =
        info.controlUrl.empty() ? L"Tailscale" : L"Headscale";

    int row = FindRow(id);
    if (row < 0) {
        LVITEMW item{};
        item.mask = LVIF_TEXT | LVIF_PARAM;
        item.iItem = ListView_GetItemCount(listView_);
        item.pszText = name.data();
        item.lParam = reinterpret_cast<LPARAM>(new std::string(id));
        row = ListView_InsertItem(listView_, &item);
    } else {
        ListView_SetItemText(listView_, row, 0, name.data());
    }
    ListView_SetItemText(listView_, row, 1, status.data());
    ListView_SetItemText(listView_, row, 2, provider.data());

    SyncSignInDialog(id, info.status, info.loginUrl);

    // The first time any tailnet is connected, offer to set up apps for it
    // (once per user; see first_run.h).
    auto prev = networks_.find(id);
    bool newlyConnected = info.status == "connected" &&
                          (prev == networks_.end() || prev->second.status != "connected");
    if (newlyConnected && !appsSetupPosted_ && !LoadAppsSetupSeen()) {
        appsSetupPosted_ = true;
        PostMessageW(hwnd_, WM_APP_SHOW_APPS_SETUP, 0,
                     reinterpret_cast<LPARAM>(new std::string(id)));
    }

    networks_[id] = std::move(info);
    UpdateSummaryLabel();
    UpdateEmptyState();
    SyncSshConfig();
}

void MainWindow::RemoveRow(const std::string &id) {
    if (id.empty())
        return;
    networks_.erase(id);
    auto dlgIt = signInDialogs_.find(id);
    if (dlgIt != signInDialogs_.end() && dlgIt->second->IsValid())
        dlgIt->second->Close();

    int row = FindRow(id);
    if (row >= 0) {
        delete reinterpret_cast<std::string *>(GetItemParam(listView_, row));
        ListView_DeleteItem(listView_, row);
    }
    UpdateSummaryLabel();
    UpdateEmptyState();
    SyncSshConfig();
}

void MainWindow::UpdateSummaryLabel() {
    int connected = 0, disconnected = 0;
    for (const auto &[id, info] : networks_) {
        if (info.status == "connected")
            connected++;
        else if (info.status == "disconnected")
            disconnected++;
    }
    std::wstring text = std::to_wstring(connected) + L" connected - " +
                        std::to_wstring(disconnected) + L" disconnected";
    SetWindowTextW(summaryLabel_, text.c_str());
}

void MainWindow::UpdateEmptyState() {
    bool empty = networks_.empty();
    ShowWindow(emptyStateLabel_, empty ? SW_SHOW : SW_HIDE);
    ShowWindow(listView_, empty ? SW_HIDE : SW_SHOW);
    ShowWindow(summaryLabel_, empty ? SW_HIDE : SW_SHOW);
}

// Colors the Status column per row.
LRESULT MainWindow::OnListCustomDraw(NMLVCUSTOMDRAW *cd) {
    switch (cd->nmcd.dwDrawStage) {
    case CDDS_PREPAINT:
        return CDRF_NOTIFYITEMDRAW;
    case CDDS_ITEMPREPAINT:
        return CDRF_NOTIFYSUBITEMDRAW;
    case CDDS_ITEMPREPAINT | CDDS_SUBITEM:
        if (cd->iSubItem == 1) {
            auto *idPtr = reinterpret_cast<std::string *>(
                GetItemParam(listView_, static_cast<int>(cd->nmcd.dwItemSpec)));
            auto it = idPtr ? networks_.find(*idPtr) : networks_.end();
            if (it != networks_.end())
                cd->clrText = StatusColor(it->second.status);
        }
        return CDRF_DODEFAULT;
    }
    return CDRF_DODEFAULT;
}

bool MainWindow::Create(HINSTANCE instance) {
    WNDCLASSW wc{};
    wc.lpfnWndProc = WndProcStatic;
    wc.hInstance = instance;
    wc.lpszClassName = L"WintailsMainWindow";
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    RegisterClassW(&wc);

    hwnd_ = CreateWindowExW(0, wc.lpszClassName, L"winTails",
                            WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
                            600, 560, nullptr, nullptr, instance, this);
    return hwnd_ != nullptr;
}

} // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR cmdLine, int cmdShow) {
    // Run by the uninstaller (installer/Product.wxs): put the user's own
    // Windows proxy setting back if "Use for Windows" changed it, then exit.
    if (cmdLine && wcscmp(cmdLine, L"--restore-system-proxy") == 0) {
        RestoreSystemProxy();
        return 0;
    }

    INITCOMMONCONTROLSEX icc{sizeof(icc), ICC_LISTVIEW_CLASSES |
                                              ICC_LINK_CLASS | ICC_BAR_CLASSES};
    InitCommonControlsEx(&icc);

    MainWindow window;
    if (!window.Create(instance))
        return 1;
    window.Show(cmdShow);

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return 0;
}
