#pragma once

#include <windows.h>

#include <string>

void CenterOverOwner(HWND hwnd, HWND owner);

void CopyTextToClipboard(HWND owner, const std::wstring& text);

// Gives every child of parent Windows' standard UI font (Segoe UI) instead of
// the bold "System" font controls get when nothing sets one. Call once its
// children exist, before showing it.
void ApplyUiFont(HWND parent);

// Pumps hwnd's messages (with IsDialogMessage so Tab/Enter/Escape work
// across its children) until *done is set by its own WM_COMMAND/WM_CLOSE
// handling, with owner disabled meanwhile. Caller destroys hwnd afterward --
// this doesn't, so callers can still read back child control state first.
void RunModalLoop(HWND hwnd, HWND owner, bool* done);
