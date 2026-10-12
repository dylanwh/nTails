#include "modal.h"

#include <cstring>

void CenterOverOwner(HWND hwnd, HWND owner) {
    RECT ownerRect, selfRect;
    GetWindowRect(owner, &ownerRect);
    GetWindowRect(hwnd, &selfRect);
    int w = selfRect.right - selfRect.left;
    int h = selfRect.bottom - selfRect.top;
    int x = ownerRect.left + ((ownerRect.right - ownerRect.left) - w) / 2;
    int y = ownerRect.top + ((ownerRect.bottom - ownerRect.top) - h) / 2;
    SetWindowPos(hwnd, nullptr, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER);
}

void CopyTextToClipboard(HWND owner, const std::wstring& text) {
    if (!OpenClipboard(owner)) return;
    EmptyClipboard();
    size_t bytes = (text.size() + 1) * sizeof(wchar_t);
    if (HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, bytes)) {
        memcpy(GlobalLock(mem), text.c_str(), bytes);
        GlobalUnlock(mem);
        if (!SetClipboardData(CF_UNICODETEXT, mem)) GlobalFree(mem); // clipboard owns it on success
    }
    CloseClipboard();
}

void ApplyUiFont(HWND parent) {
    // Created once and never freed: it lives as long as the process.
    static HFONT font = [] {
        NONCLIENTMETRICSW ncm{};
        ncm.cbSize = sizeof(ncm);
        SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(ncm), &ncm, 0);
        return CreateFontIndirectW(&ncm.lfMessageFont);
    }();
    EnumChildWindows(
        parent,
        [](HWND child, LPARAM lParam) -> BOOL {
            SendMessageW(child, WM_SETFONT, static_cast<WPARAM>(lParam), FALSE);
            return TRUE;
        },
        reinterpret_cast<LPARAM>(font));
}

void RunModalLoop(HWND hwnd, HWND owner, bool* done) {
    ApplyUiFont(hwnd);
    EnableWindow(owner, FALSE);
    ShowWindow(hwnd, SW_SHOW);
    SetForegroundWindow(hwnd);

    MSG msg;
    while (!*done && GetMessageW(&msg, nullptr, 0, 0)) {
        if (!IsDialogMessageW(hwnd, &msg)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    EnableWindow(owner, TRUE);
    SetForegroundWindow(owner);
}
