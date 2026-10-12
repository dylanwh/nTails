#include "signin_dialog.h"

#include <commctrl.h>
#include <qrencode.h>
#include <shellapi.h>

#include "convert.h"
#include "modal.h"

namespace {

constexpr int kQrBoxSize = 300;
constexpr int kMarginX = 20;
constexpr int kQrTop = 20;
constexpr int kLinkTop = kQrTop + kQrBoxSize + 12;
constexpr int kLinkHeight = 24;
constexpr int kButtonTop = kLinkTop + kLinkHeight + 12;
constexpr int kButtonHeight = 28;
constexpr int kClientWidth = kQrBoxSize + kMarginX * 2;
constexpr int kClientHeight = kButtonTop + kButtonHeight + 20;

constexpr int kLinkId = 301;
constexpr int kCopyBtnId = 302;
constexpr int kWaitingLabelId = 303;

// Escapes the characters SysLink's markup parser treats specially, for text
// placed between its <a>...</a> tags.
std::wstring EscapeForSysLink(const std::wstring& s) {
    std::wstring out;
    out.reserve(s.size());
    for (wchar_t c : s) {
        switch (c) {
            case L'&': out += L"&amp;"; break;
            case L'<': out += L"&lt;"; break;
            case L'>': out += L"&gt;"; break;
            default: out += c;
        }
    }
    return out;
}

std::wstring TruncateForDisplay(const std::wstring& s, size_t maxLen) {
    if (s.size() <= maxLen) return s;
    return s.substr(0, maxLen - 1) + L"...";
}

} // namespace

LRESULT CALLBACK SignInDialog::WndProcStatic(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    SignInDialog* self;
    if (msg == WM_NCCREATE) {
        auto* cs = reinterpret_cast<CREATESTRUCTW*>(lParam);
        self = static_cast<SignInDialog*>(cs->lpCreateParams);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
        self->hwnd_ = hwnd;
    } else {
        self = reinterpret_cast<SignInDialog*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    }
    if (!self) return DefWindowProcW(hwnd, msg, wParam, lParam);
    return self->WndProc(msg, wParam, lParam);
}

LRESULT SignInDialog::WndProc(UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
        case WM_CREATE:
            OnCreate();
            return 0;
        case WM_PAINT:
            OnPaint();
            return 0;
        case WM_NOTIFY:
            OnNotify(lParam);
            return 0;
        case WM_CTLCOLORSTATIC:
            // The link and labels default to the grey dialog color; match
            // this window's white background (see wc.hbrBackground).
            SetBkColor(reinterpret_cast<HDC>(wParam), RGB(255, 255, 255));
            return reinterpret_cast<LRESULT>(GetStockObject(WHITE_BRUSH));
        case WM_COMMAND:
            if (LOWORD(wParam) == kCopyBtnId && HIWORD(wParam) == BN_CLICKED) OnCopyClicked();
            return 0;
        case WM_CLOSE:
            DestroyWindow(hwnd_);
            return 0;
        case WM_NCDESTROY: {
            // Last message this window will ever receive -- safe to tell the
            // owner to drop us now, unlike at WM_DESTROY, which still has
            // child-window and other cleanup messages in flight.
            auto cb = onClosed_;
            auto id = networkId_;
            hwnd_ = nullptr;
            if (cb) cb(id);
            return 0;
        }
    }
    return DefWindowProcW(hwnd_, msg, wParam, lParam);
}

void SignInDialog::OnCreate() {
    HINSTANCE inst = reinterpret_cast<HINSTANCE>(GetWindowLongPtrW(hwnd_, GWLP_HINSTANCE));

    waitingLabel_ = CreateWindowExW(0, L"STATIC", L"Waiting for sign-in link...",
                                     WS_CHILD | WS_VISIBLE | SS_CENTER,
                                     kMarginX, kQrTop + kQrBoxSize / 2 - 10, kQrBoxSize, 20,
                                     hwnd_, reinterpret_cast<HMENU>(kWaitingLabelId), inst, nullptr);

    linkCtrl_ = CreateWindowExW(0, WC_LINK, L"", WS_CHILD | WS_TABSTOP,
                                 kMarginX, kLinkTop, kQrBoxSize, kLinkHeight,
                                 hwnd_, reinterpret_cast<HMENU>(kLinkId), inst, nullptr);

    copyBtn_ = CreateWindowExW(0, L"BUTTON", L"Copy Link", WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON,
                                kMarginX, kButtonTop, 120, kButtonHeight,
                                hwnd_, reinterpret_cast<HMENU>(kCopyBtnId), inst, nullptr);
}

void SignInDialog::OnPaint() {
    PAINTSTRUCT ps;
    HDC hdc = BeginPaint(hwnd_, &ps);

    if (hasUrl_ && qrSize_ > 0) {
        int moduleCount = qrSize_ + 8; // qrencode's matrix plus a 4-module quiet zone each side
        int moduleSize = kQrBoxSize / moduleCount;
        if (moduleSize < 1) moduleSize = 1;
        int drawnSize = moduleSize * moduleCount;
        int originX = kMarginX + (kQrBoxSize - drawnSize) / 2;
        int originY = kQrTop + (kQrBoxSize - drawnSize) / 2;

        HBRUSH black = reinterpret_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
        for (int row = 0; row < qrSize_; row++) {
            for (int col = 0; col < qrSize_; col++) {
                if (!qrDark_[row * qrSize_ + col]) continue;
                RECT r{originX + (4 + col) * moduleSize, originY + (4 + row) * moduleSize,
                       originX + (4 + col + 1) * moduleSize, originY + (4 + row + 1) * moduleSize};
                FillRect(hdc, &r, black);
            }
        }
    }

    EndPaint(hwnd_, &ps);
}

void SignInDialog::OnNotify(LPARAM lParam) {
    auto* hdr = reinterpret_cast<NMHDR*>(lParam);
    if (hdr->hwndFrom == linkCtrl_ && (hdr->code == NM_CLICK || hdr->code == NM_RETURN)) {
        ShellExecuteW(hwnd_, L"open", Utf8ToWide(url_).c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    }
}

void SignInDialog::OnCopyClicked() {
    CopyTextToClipboard(hwnd_, Utf8ToWide(url_));
}

void SignInDialog::RegenerateQr() {
    QRcode* qr = QRcode_encodeString(url_.c_str(), 0, QR_ECLEVEL_M, QR_MODE_8, 1);
    if (!qr) {
        qrSize_ = 0;
        qrDark_.clear();
        return;
    }
    qrSize_ = qr->width;
    qrDark_.assign(qr->data, qr->data + (qrSize_ * qrSize_));
    for (auto& v : qrDark_) v &= 1; // bit 0 is the module color; other bits are qrencode-internal
    QRcode_free(qr);
}

bool SignInDialog::Create(HWND owner, HINSTANCE instance, const std::string& networkId) {
    networkId_ = networkId;

    static bool registered = false;
    if (!registered) {
        WNDCLASSW wc{};
        wc.lpfnWndProc = WndProcStatic;
        wc.hInstance = instance;
        wc.lpszClassName = L"WintailsSignIn";
        wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        wc.hbrBackground = reinterpret_cast<HBRUSH>(GetStockObject(WHITE_BRUSH));
        RegisterClassW(&wc);
        registered = true;
    }

    RECT rect{0, 0, kClientWidth, kClientHeight};
    AdjustWindowRectEx(&rect, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, FALSE, 0);

    hwnd_ = CreateWindowExW(WS_EX_DLGMODALFRAME, L"WintailsSignIn", L"Sign In",
                             WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
                             CW_USEDEFAULT, CW_USEDEFAULT, rect.right - rect.left, rect.bottom - rect.top,
                             owner, nullptr, instance, this);
    if (!hwnd_) return false;

    ApplyUiFont(hwnd_);
    ShowWindow(hwnd_, SW_SHOW);
    return true;
}

void SignInDialog::SetWaiting() {
    hasUrl_ = false;
    url_.clear();
    ShowWindow(waitingLabel_, SW_SHOW);
    ShowWindow(linkCtrl_, SW_HIDE);
    ShowWindow(copyBtn_, SW_HIDE);
    InvalidateRect(hwnd_, nullptr, TRUE);
}

void SignInDialog::SetUrl(const std::string& url) {
    if (url.empty()) {
        SetWaiting();
        return;
    }
    url_ = url;
    hasUrl_ = true;
    RegenerateQr();

    std::wstring display = TruncateForDisplay(Utf8ToWide(url_), 56);
    std::wstring markup = L"<a href=\"#\">" + EscapeForSysLink(display) + L"</a>";
    SetWindowTextW(linkCtrl_, markup.c_str());

    ShowWindow(waitingLabel_, SW_HIDE);
    ShowWindow(linkCtrl_, SW_SHOW);
    ShowWindow(copyBtn_, SW_SHOW);
    InvalidateRect(hwnd_, nullptr, TRUE);
}

void SignInDialog::Close() {
    if (hwnd_) DestroyWindow(hwnd_);
}
