#include "dialogs.h"

#include <vector>

#include "modal.h"

namespace {

// --- Network type choice -------------------------------------------------

constexpr int kTailscaleButtonId = 101;
constexpr int kHeadscaleButtonId = 102;

struct TypeChoiceState {
    bool done = false;
    NetworkTypeChoice result = NetworkTypeChoice::Cancel;
};

LRESULT CALLBACK TypeChoiceWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    auto* state = reinterpret_cast<TypeChoiceState*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    switch (msg) {
        case WM_NCCREATE:
            SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                               reinterpret_cast<LONG_PTR>(reinterpret_cast<CREATESTRUCTW*>(lParam)->lpCreateParams));
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        case WM_CREATE: {
            HINSTANCE inst = reinterpret_cast<CREATESTRUCTW*>(lParam)->hInstance;
            CreateWindowExW(0, L"STATIC", L"Choose a tailnet type:", WS_CHILD | WS_VISIBLE,
                             16, 16, 300, 20, hwnd, nullptr, inst, nullptr);
            CreateWindowExW(0, L"BUTTON", L"Tailscale", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON,
                             40, 50, 110, 30, hwnd, reinterpret_cast<HMENU>(kTailscaleButtonId), inst, nullptr);
            CreateWindowExW(0, L"BUTTON", L"Headscale", WS_CHILD | WS_VISIBLE | WS_TABSTOP,
                             180, 50, 110, 30, hwnd, reinterpret_cast<HMENU>(kHeadscaleButtonId), inst, nullptr);
            return 0;
        }
        case WM_COMMAND:
            if (LOWORD(wParam) == kTailscaleButtonId) {
                state->result = NetworkTypeChoice::Tailscale;
                state->done = true;
            } else if (LOWORD(wParam) == kHeadscaleButtonId) {
                state->result = NetworkTypeChoice::Headscale;
                state->done = true;
            }
            return 0;
        case WM_CLOSE:
            state->result = NetworkTypeChoice::Cancel;
            state->done = true;
            return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

// --- Headscale URL prompt -------------------------------------------------

constexpr int kUrlEditId = 201;

struct UrlPromptState {
    HWND edit = nullptr;
    bool done = false;
    bool ok = false;
};

LRESULT CALLBACK UrlPromptWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    auto* state = reinterpret_cast<UrlPromptState*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    switch (msg) {
        case WM_NCCREATE:
            SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                               reinterpret_cast<LONG_PTR>(reinterpret_cast<CREATESTRUCTW*>(lParam)->lpCreateParams));
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        case WM_CREATE: {
            HINSTANCE inst = reinterpret_cast<CREATESTRUCTW*>(lParam)->hInstance;
            CreateWindowExW(0, L"STATIC", L"Headscale server URL:", WS_CHILD | WS_VISIBLE,
                             16, 16, 320, 20, hwnd, nullptr, inst, nullptr);
            state->edit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP,
                                           16, 40, 320, 24, hwnd, reinterpret_cast<HMENU>(kUrlEditId), inst, nullptr);
            CreateWindowExW(0, L"BUTTON", L"Log In", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON,
                            176, 78, 78, 28, hwnd, reinterpret_cast<HMENU>(IDOK), inst, nullptr);
            CreateWindowExW(0, L"BUTTON", L"Cancel", WS_CHILD | WS_VISIBLE | WS_TABSTOP,
                            258, 78, 78, 28, hwnd, reinterpret_cast<HMENU>(IDCANCEL), inst, nullptr);
            SetFocus(state->edit);
            return 0;
        }
        case WM_COMMAND:
            if (LOWORD(wParam) == IDOK) {
                state->ok = true;
                state->done = true;
            } else if (LOWORD(wParam) == IDCANCEL) {
                state->ok = false;
                state->done = true;
            }
            return 0;
        case WM_CLOSE:
            state->ok = false;
            state->done = true;
            return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

} // namespace

NetworkTypeChoice ChooseNetworkType(HWND owner, HINSTANCE instance) {
    static bool registered = false;
    if (!registered) {
        WNDCLASSW wc{};
        wc.lpfnWndProc = TypeChoiceWndProc;
        wc.hInstance = instance;
        wc.lpszClassName = L"WintailsTypeChoice";
        wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_BTNFACE + 1);
        RegisterClassW(&wc);
        registered = true;
    }

    TypeChoiceState state;
    HWND hwnd = CreateWindowExW(WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT, L"WintailsTypeChoice", L"Log In to Tailnet",
                                 WS_POPUP | WS_CAPTION | WS_SYSMENU,
                                 CW_USEDEFAULT, CW_USEDEFAULT, 350, 130, owner, nullptr, instance, &state);
    CenterOverOwner(hwnd, owner);
    RunModalLoop(hwnd, owner, &state.done);
    DestroyWindow(hwnd);
    return state.result;
}

bool PromptForHeadscaleUrl(HWND owner, HINSTANCE instance, std::wstring& outUrl) {
    static bool registered = false;
    if (!registered) {
        WNDCLASSW wc{};
        wc.lpfnWndProc = UrlPromptWndProc;
        wc.hInstance = instance;
        wc.lpszClassName = L"WintailsUrlPrompt";
        wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_BTNFACE + 1);
        RegisterClassW(&wc);
        registered = true;
    }

    UrlPromptState state;
    HWND hwnd = CreateWindowExW(WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT, L"WintailsUrlPrompt", L"Headscale Server",
                                 WS_POPUP | WS_CAPTION | WS_SYSMENU,
                                 CW_USEDEFAULT, CW_USEDEFAULT, 360, 150, owner, nullptr, instance, &state);
    CenterOverOwner(hwnd, owner);
    RunModalLoop(hwnd, owner, &state.done);

    if (state.ok) {
        int len = GetWindowTextLengthW(state.edit);
        std::vector<wchar_t> buf(len + 1);
        GetWindowTextW(state.edit, buf.data(), len + 1);
        outUrl.assign(buf.data(), len);
    }
    DestroyWindow(hwnd);
    return state.ok;
}
