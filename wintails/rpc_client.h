#pragma once

#include <windows.h>
#include <jansson.h>

#include <functional>
#include <string>
#include <unordered_map>

// Posted to the owning window once per complete line read from the child's
// stdout. wParam is unused; lParam is a heap-allocated std::string* owned by
// the message (RpcClient::HandleLine takes ownership and frees it).
#define WM_APP_RPC_LINE (WM_APP + 1)

// Posted once per complete line read from the child's stderr -- ntailsd.exe's
// own log output (docs/rpc-protocol.md reserves stderr for exactly this).
// wParam is unused; lParam is a heap-allocated std::string* the window must
// delete after reading.
#define WM_APP_RPC_STDERR_LINE (WM_APP + 4)

// A user-facing sentence for an ntailsd Error object ({code, ...fields}, see
// docs/rpc-protocol.md's Errors section). ntailsd sends only error codes,
// so all of wintails' error wording lives here.
std::string DescribeRpcError(json_t* error);

// Drives ntailsd.exe's "rpc" subcommand as a child process over pipes,
// speaking the protocol in docs/rpc-protocol.md. All public methods except
// the reader thread's internals are meant to be called from the window
// thread that owns notifyWindow; responses and events are both delivered
// back on that same thread via WM_APP_RPC_LINE, so no locking is needed
// around the pending-request map.
class RpcClient {
public:
    // data is a borrowed reference, valid only for the duration of the
    // callback -- copy anything you need out of it rather than holding the
    // pointer. On failure, error is DescribeRpcError's sentence for it.
    using ResponseCallback = std::function<void(bool ok, json_t* data, const std::string& error)>;
    using EventCallback = std::function<void(const std::string& name, json_t* data)>;

    ~RpcClient();

    // Spawns commandLine (e.g. L"ntailsd.exe rpc") with redirected stdio.
    // notifyWindow receives WM_APP_RPC_LINE for every response/event.
    bool Start(HWND notifyWindow, const std::wstring& commandLine);

    // Sends {"id":<next id>,"cmd":cmd,"args":args}. Takes ownership of args
    // (pass a new reference, or nullptr for no args) the same way jansson's
    // own json_object_set_new does. Returns the request id.
    int Send(const std::string& cmd, json_t* args, ResponseCallback callback);

    void SetEventCallback(EventCallback callback) { onEvent_ = std::move(callback); }

    // Call from the window procedure on WM_APP_RPC_LINE with the posted
    // std::string* in lParam. Parses the line, dispatches to the matching
    // pending callback or to the event callback, and deletes line.
    void HandleLine(std::string* line);

    // Sends "quit", waits briefly for the child to exit, then forcibly
    // terminates it if it hasn't. Safe to call from WM_DESTROY.
    void Stop();

private:
    static DWORD WINAPI ReaderThreadMain(LPVOID param);
    void ReaderLoop();
    static DWORD WINAPI StderrReaderThreadMain(LPVOID param);
    void StderrReaderLoop();

    HWND notifyWindow_ = nullptr;
    HANDLE childProcess_ = nullptr;
    HANDLE stdinWrite_ = nullptr;
    HANDLE stdoutRead_ = nullptr;
    HANDLE stderrRead_ = nullptr;
    HANDLE readerThread_ = nullptr;
    HANDLE stderrReaderThread_ = nullptr;

    int nextId_ = 1;
    std::unordered_map<int, ResponseCallback> pending_;
    EventCallback onEvent_;
};
