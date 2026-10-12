#include "first_run.h"

#include <windowsx.h>

#include "modal.h"
#include "system_proxy.h"

namespace {

constexpr wchar_t kRegKey[] = L"Software\\ntails";
constexpr wchar_t kWelcomeSeenValue[] = L"WelcomeSeen";
constexpr wchar_t kAppsSetupSeenValue[] = L"AppsSetupSeen";

bool LoadFlag(const wchar_t* name) {
    DWORD value = 0, size = sizeof(value);
    return RegGetValueW(HKEY_CURRENT_USER, kRegKey, name, RRF_RT_REG_DWORD, nullptr, &value, &size) ==
               ERROR_SUCCESS &&
           value != 0;
}

void SaveFlag(const wchar_t* name) {
    HKEY key;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, kRegKey, 0, nullptr, 0, KEY_WRITE, nullptr, &key, nullptr) !=
        ERROR_SUCCESS) {
        return;
    }
    DWORD one = 1;
    RegSetValueExW(key, name, 0, REG_DWORD, reinterpret_cast<const BYTE*>(&one), sizeof(one));
    RegCloseKey(key);
}

// Creates a top-level dialog-style window of the given client size,
// registering its class on first use.
HWND CreateDialogWindow(HWND owner, HINSTANCE instance, const wchar_t* className, WNDPROC proc,
                        const wchar_t* title, int clientWidth, int clientHeight, void* state) {
    WNDCLASSW wc{};
    if (!GetClassInfoW(instance, className, &wc)) {
        wc.lpfnWndProc = proc;
        wc.hInstance = instance;
        wc.lpszClassName = className;
        wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_BTNFACE + 1);
        RegisterClassW(&wc);
    }
    RECT rect{0, 0, clientWidth, clientHeight};
    AdjustWindowRectEx(&rect, WS_POPUP | WS_CAPTION | WS_SYSMENU, FALSE, WS_EX_DLGMODALFRAME);
    HWND hwnd = CreateWindowExW(WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT, className, title,
                                WS_POPUP | WS_CAPTION | WS_SYSMENU, CW_USEDEFAULT, CW_USEDEFAULT,
                                rect.right - rect.left, rect.bottom - rect.top, owner, nullptr, instance, state);
    CenterOverOwner(hwnd, owner);
    return hwnd;
}

HWND Label(HWND parent, HINSTANCE inst, const std::wstring& text, int x, int y, int w, int h) {
    return CreateWindowExW(0, L"STATIC", text.c_str(), WS_CHILD | WS_VISIBLE, x, y, w, h, parent, nullptr, inst,
                           nullptr);
}

HWND Button(HWND parent, HINSTANCE inst, const wchar_t* text, int id, int x, int y, int w, bool isDefault) {
    DWORD style = WS_CHILD | WS_VISIBLE | WS_TABSTOP | (isDefault ? BS_DEFPUSHBUTTON : 0);
    return CreateWindowExW(0, L"BUTTON", text, style, x, y, w, 28, parent, reinterpret_cast<HMENU>(id), inst,
                           nullptr);
}

HWND Checkbox(HWND parent, HINSTANCE inst, const std::wstring& text, int id, int x, int y, int w, bool checked) {
    HWND h = CreateWindowExW(0, L"BUTTON", text.c_str(), WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_AUTOCHECKBOX, x,
                             y, w, 22, parent, reinterpret_cast<HMENU>(id), inst, nullptr);
    Button_SetCheck(h, checked ? BST_CHECKED : BST_UNCHECKED);
    return h;
}

// --- Welcome --------------------------------------------------------------

struct WelcomeState {
    bool done = false;
    bool addTailnet = false;
};

LRESULT CALLBACK WelcomeWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    auto* state = reinterpret_cast<WelcomeState*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    switch (msg) {
        case WM_NCCREATE:
            SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                              reinterpret_cast<LONG_PTR>(reinterpret_cast<CREATESTRUCTW*>(lParam)->lpCreateParams));
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        case WM_CREATE: {
            HINSTANCE inst = reinterpret_cast<CREATESTRUCTW*>(lParam)->hInstance;
            Label(hwnd, inst,
                  L"winTails connects this PC to one or more tailnets (Tailscale or Headscale) without installing "
                  L"Tailscale or changing the rest of your network.",
                  20, 18, 420, 52);
            Label(hwnd, inst,
                  L"It runs small local proxies. Once connected, winTails can point Windows at them so your "
                  L"browser and other apps reach names like server.your-tailnet.ts.net, and can set up ssh.",
                  20, 78, 420, 68);
            Label(hwnd, inst, L"First, add a tailnet and sign in.", 20, 154, 420, 20);
            Button(hwnd, inst, L"Add a Tailnet", IDOK, 236, 190, 110, true);
            Button(hwnd, inst, L"Not Now", IDCANCEL, 354, 190, 86, false);
            return 0;
        }
        case WM_COMMAND:
            if (LOWORD(wParam) == IDOK || LOWORD(wParam) == IDCANCEL) {
                state->addTailnet = LOWORD(wParam) == IDOK;
                state->done = true;
            }
            return 0;
        case WM_CLOSE:
            state->done = true;
            return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

// --- Set Up Your Apps -----------------------------------------------------

constexpr int kSystemPacCheckId = 501;
constexpr int kSshCheckId = 502;
constexpr int kRepickCheckId = 503;

struct AppsSetupState {
    const AppsSetupContext* context = nullptr;
    AppsSetupChoice choice;
    HWND systemPacCheck = nullptr;
    HWND sshCheck = nullptr;
    HWND repickCheck = nullptr;
    bool done = false;
    bool finished = false;
};

void OnFinish(AppsSetupState* state, HWND hwnd) {
    state->choice.useSystemPac = Button_GetCheck(state->systemPacCheck) == BST_CHECKED;
    state->choice.updateSshConfig = Button_GetCheck(state->sshCheck) == BST_CHECKED;
    state->choice.repickPorts = state->repickCheck && Button_GetCheck(state->repickCheck) == BST_CHECKED;

    // As in Settings: ask before replacing the user's own proxy.
    SystemProxy existing;
    if (state->choice.useSystemPac && !LoadUseSystemPac() && QuerySystemProxy(&existing) &&
        HasForeignSystemProxy(existing)) {
        int answer = MessageBoxW(hwnd,
                                 L"Windows is already set to use a proxy. Replace it with winTails' PAC file?\n\n"
                                 L"winTails will put your current setting back if you turn \"Use for Windows\" off "
                                 L"in Settings.",
                                 L"Set Up Your Apps", MB_ICONQUESTION | MB_YESNO);
        if (answer != IDYES) {
            Button_SetCheck(state->systemPacCheck, BST_UNCHECKED);
            return;
        }
    }
    state->finished = true;
    state->done = true;
}

LRESULT CALLBACK AppsSetupWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    auto* state = reinterpret_cast<AppsSetupState*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    switch (msg) {
        case WM_NCCREATE:
            SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                              reinterpret_cast<LONG_PTR>(reinterpret_cast<CREATESTRUCTW*>(lParam)->lpCreateParams));
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        case WM_CREATE: {
            state = reinterpret_cast<AppsSetupState*>(reinterpret_cast<CREATESTRUCTW*>(lParam)->lpCreateParams);
            HINSTANCE inst = reinterpret_cast<CREATESTRUCTW*>(lParam)->hInstance;
            const AppsSetupContext& ctx = *state->context;
            const std::wstring domain = ctx.domain.empty() ? L"your tailnet" : ctx.domain;
            int y = 18;

            Label(hwnd, inst, L"You're connected to " + domain + L". Choose how your apps should reach it:", 20, y,
                  440, 20);
            y += 34;

            state->systemPacCheck = Checkbox(hwnd, inst, L"Use for Windows", kSystemPacCheckId, 20, y, 420,
                                             state->choice.useSystemPac);
            Label(hwnd, inst,
                  L"Edge, Chrome, Firefox and other apps reach " + domain +
                      L" names. If you already use a proxy, it's saved and put back when you turn this off.",
                  40, y + 24, 420, 36);
            y += 72;

            state->sshCheck = Checkbox(hwnd, inst, L"Update ssh config", kSshCheckId, 20, y, 420,
                                       state->choice.updateSshConfig);
            Label(hwnd, inst,
                  L"Makes \"ssh <device>." + domain + L"\" work, by adding a marked block to " + ctx.sshConfigPath +
                      L".",
                  40, y + 24, 420, 36);
            y += 72;

            if (!ctx.blocked.empty()) {
                std::wstring names;
                for (size_t i = 0; i < ctx.blocked.size(); ++i) {
                    names += (i == 0 ? L"" : i + 1 == ctx.blocked.size() ? L" and " : L", ") + ctx.blocked[i];
                }
                state->repickCheck = Checkbox(hwnd, inst, L"Let winTails pick free ports", kRepickCheckId, 20, y, 420,
                                              state->choice.repickPorts);
                Label(hwnd, inst, L"The " + names + L" couldn't start: another program is using its port.", 40,
                      y + 24, 420, 36);
                y += 72;
            }

            Label(hwnd, inst,
                  L"Try it: open http://<device>." + domain +
                      L" in your browser, using the name of a device on your tailnet.",
                  20, y, 440, 36);
            y += 44;
            Label(hwnd, inst,
                  L"Closing the winTails window keeps it running in the notification area. To quit, right-click its "
                  L"icon there and choose Quit. You can change all of this later in Settings.",
                  20, y, 440, 52);
            y += 64;

            Button(hwnd, inst, L"Finish", IDOK, 282, y, 86, true);
            Button(hwnd, inst, L"Skip", IDCANCEL, 376, y, 86, false);

            RECT rect{0, 0, 480, y + 44};
            AdjustWindowRectEx(&rect, WS_POPUP | WS_CAPTION | WS_SYSMENU, FALSE, WS_EX_DLGMODALFRAME);
            SetWindowPos(hwnd, nullptr, 0, 0, rect.right - rect.left, rect.bottom - rect.top,
                         SWP_NOMOVE | SWP_NOZORDER);
            return 0;
        }
        case WM_COMMAND:
            if (LOWORD(wParam) == IDOK) {
                OnFinish(state, hwnd);
            } else if (LOWORD(wParam) == IDCANCEL) {
                state->done = true;
            }
            return 0;
        case WM_CLOSE:
            state->done = true;
            return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

} // namespace

bool LoadWelcomeSeen() { return LoadFlag(kWelcomeSeenValue); }
void SaveWelcomeSeen() { SaveFlag(kWelcomeSeenValue); }
bool LoadAppsSetupSeen() { return LoadFlag(kAppsSetupSeenValue); }
void SaveAppsSetupSeen() { SaveFlag(kAppsSetupSeenValue); }

bool ShowWelcomeDialog(HWND owner, HINSTANCE instance) {
    WelcomeState state;
    HWND hwnd = CreateDialogWindow(owner, instance, L"WintailsWelcome", WelcomeWndProc, L"Welcome to winTails", 460,
                                   236, &state);
    RunModalLoop(hwnd, owner, &state.done);
    DestroyWindow(hwnd);
    return state.addTailnet;
}

bool ShowAppsSetupDialog(HWND owner, HINSTANCE instance, const AppsSetupContext& context, AppsSetupChoice* choice) {
    AppsSetupState state;
    state.context = &context;
    state.choice = *choice;
    // Sized to fit its content in WM_CREATE.
    HWND hwnd = CreateDialogWindow(owner, instance, L"WintailsAppsSetup", AppsSetupWndProc, L"Set Up Your Apps",
                                   480, 400, &state);
    CenterOverOwner(hwnd, owner); // again, now that its size is known
    RunModalLoop(hwnd, owner, &state.done);
    DestroyWindow(hwnd);
    if (state.finished) *choice = state.choice;
    return state.finished;
}
