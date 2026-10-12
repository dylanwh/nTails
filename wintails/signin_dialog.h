#pragma once

#include <windows.h>

#include <functional>
#include <string>
#include <vector>

// Modeless sign-in window: QR code, clickable link, copy button. Modeless so
// the main window stays usable while waiting on a phone scan.
class SignInDialog {
public:
    using ClosedCallback = std::function<void(const std::string& networkId)>;

    bool Create(HWND owner, HINSTANCE instance, const std::string& networkId);

    // No URL yet -- shows a placeholder instead of the QR/link/copy controls.
    void SetWaiting();

    // Renders the QR code and enables the link/copy controls for url.
    void SetUrl(const std::string& url);

    void Close();
    bool IsValid() const { return hwnd_ != nullptr; }

    // Invoked (with networkId) once the window is fully destroyed -- the
    // owner should drop its reference to this dialog at that point, not
    // before (Windows still has cleanup messages in flight until then).
    void SetOnClosed(ClosedCallback cb) { onClosed_ = std::move(cb); }

private:
    static LRESULT CALLBACK WndProcStatic(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
    LRESULT WndProc(UINT msg, WPARAM wParam, LPARAM lParam);

    void OnCreate();
    void OnPaint();
    void OnNotify(LPARAM lParam);
    void OnCopyClicked();
    void RegenerateQr();
    void Relayout();

    HWND hwnd_ = nullptr;
    HWND linkCtrl_ = nullptr;
    HWND copyBtn_ = nullptr;
    HWND waitingLabel_ = nullptr;

    std::string networkId_;
    std::string url_;
    bool hasUrl_ = false;
    ClosedCallback onClosed_;

    int qrSize_ = 0; // modules per side
    std::vector<unsigned char> qrDark_; // qrSize_ * qrSize_, 1 = dark module
};
