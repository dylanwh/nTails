#pragma once

#include <windows.h>

#include <string>
#include <vector>

// The first-run guide: a Welcome dialog when there are no tailnets yet, and
// a "Set Up Your Apps" dialog once the first tailnet connects. Each shows
// once, remembered in HKCU\Software\ntails; the main window's empty state
// and Settings cover the same ground for anyone who skips them.

// Whether each step has been shown already.
bool LoadWelcomeSeen();
void SaveWelcomeSeen();
bool LoadAppsSetupSeen();
void SaveAppsSetupSeen();

// Returns true if the user chose "Add a Tailnet", false for "Not Now".
bool ShowWelcomeDialog(HWND owner, HINSTANCE instance);

struct AppsSetupContext {
    std::wstring domain;                // the tailnet that just connected
    std::vector<std::wstring> blocked;  // listeners that failed to start, e.g. L"PAC file"
    std::wstring sshConfigPath;         // where "Update ssh config" would write
};

struct AppsSetupChoice {
    bool useSystemPac = true;   // pre-ticked
    bool updateSshConfig = false; // opt-in: it edits a file the user may manage
    bool repickPorts = true;    // only offered when something is blocked
};

// Returns false if the user chose "Skip" (choice untouched). Asks before
// "Use for Windows" replaces a proxy the user already has, like Settings.
bool ShowAppsSetupDialog(HWND owner, HINSTANCE instance, const AppsSetupContext& context, AppsSetupChoice* choice);
