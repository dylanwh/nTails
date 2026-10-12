#pragma once

#include <windows.h>

#include <string>

enum class NetworkTypeChoice { Cancel, Tailscale, Headscale };

// Modal "Choose a tailnet type:" prompt.
NetworkTypeChoice ChooseNetworkType(HWND owner, HINSTANCE instance);

// Modal "Server URL:" prompt. Returns false if the user cancels; otherwise
// outUrl holds whatever they typed (not validated here).
bool PromptForHeadscaleUrl(HWND owner, HINSTANCE instance, std::wstring& outUrl);
