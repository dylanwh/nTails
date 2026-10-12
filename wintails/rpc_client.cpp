#include "rpc_client.h"

#include <vector>

RpcClient::~RpcClient() {
    if (childProcess_) {
        Stop();
    }
}

bool RpcClient::Start(HWND notifyWindow, const std::wstring& commandLine) {
    notifyWindow_ = notifyWindow;

    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;

    HANDLE childStdinRead = nullptr, childStdoutWrite = nullptr, childStderrWrite = nullptr;
    if (!CreatePipe(&childStdinRead, &stdinWrite_, &sa, 0)) return false;
    if (!CreatePipe(&stdoutRead_, &childStdoutWrite, &sa, 0)) return false;
    if (!CreatePipe(&stderrRead_, &childStderrWrite, &sa, 0)) return false;
    SetHandleInformation(stdinWrite_, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(stdoutRead_, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(stderrRead_, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = childStdinRead;
    si.hStdOutput = childStdoutWrite;
    si.hStdError = childStderrWrite;

    PROCESS_INFORMATION pi{};
    std::vector<wchar_t> cmdLineBuf(commandLine.begin(), commandLine.end());
    cmdLineBuf.push_back(L'\0');

    BOOL ok = CreateProcessW(nullptr, cmdLineBuf.data(), nullptr, nullptr, TRUE,
                              CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi);

    CloseHandle(childStdinRead);
    CloseHandle(childStdoutWrite);
    CloseHandle(childStderrWrite);

    if (!ok) {
        CloseHandle(stdinWrite_);
        CloseHandle(stdoutRead_);
        CloseHandle(stderrRead_);
        stdinWrite_ = stdoutRead_ = stderrRead_ = nullptr;
        return false;
    }

    CloseHandle(pi.hThread);
    childProcess_ = pi.hProcess;

    readerThread_ = CreateThread(nullptr, 0, ReaderThreadMain, this, 0, nullptr);
    stderrReaderThread_ = CreateThread(nullptr, 0, StderrReaderThreadMain, this, 0, nullptr);
    return readerThread_ != nullptr && stderrReaderThread_ != nullptr;
}

DWORD WINAPI RpcClient::ReaderThreadMain(LPVOID param) {
    static_cast<RpcClient*>(param)->ReaderLoop();
    return 0;
}

void RpcClient::ReaderLoop() {
    std::string buffer;
    char chunk[4096];
    for (;;) {
        DWORD n = 0;
        if (!ReadFile(stdoutRead_, chunk, sizeof(chunk), &n, nullptr) || n == 0) {
            return; // child's stdout closed, i.e. it exited
        }
        buffer.append(chunk, n);
        size_t newline;
        while ((newline = buffer.find('\n')) != std::string::npos) {
            auto* line = new std::string(buffer.substr(0, newline));
            buffer.erase(0, newline + 1);
            PostMessageW(notifyWindow_, WM_APP_RPC_LINE, 0, reinterpret_cast<LPARAM>(line));
        }
    }
}

DWORD WINAPI RpcClient::StderrReaderThreadMain(LPVOID param) {
    static_cast<RpcClient*>(param)->StderrReaderLoop();
    return 0;
}

// Stderr counterpart of ReaderLoop. Separate message so log lines are never
// parsed as responses.
void RpcClient::StderrReaderLoop() {
    std::string buffer;
    char chunk[4096];
    for (;;) {
        DWORD n = 0;
        if (!ReadFile(stderrRead_, chunk, sizeof(chunk), &n, nullptr) || n == 0) {
            return;
        }
        buffer.append(chunk, n);
        size_t newline;
        while ((newline = buffer.find('\n')) != std::string::npos) {
            auto* line = new std::string(buffer.substr(0, newline));
            buffer.erase(0, newline + 1);
            PostMessageW(notifyWindow_, WM_APP_RPC_STDERR_LINE, 0, reinterpret_cast<LPARAM>(line));
        }
    }
}

int RpcClient::Send(const std::string& cmd, json_t* args, ResponseCallback callback) {
    int id = nextId_++;
    pending_[id] = std::move(callback);

    json_t* req = json_object(); // exactly id, cmd, and args (docs/rpc-protocol.md)
    json_object_set_new(req, "id", json_integer(id));
    json_object_set_new(req, "cmd", json_string(cmd.c_str()));
    if (args) json_object_set_new(req, "args", args);

    char* text = json_dumps(req, JSON_COMPACT);
    json_decref(req);

    std::string line(text);
    free(text);
    line += '\n';

    DWORD written = 0;
    WriteFile(stdinWrite_, line.data(), static_cast<DWORD>(line.size()), &written, nullptr);

    return id;
}

namespace {

std::string ListenerName(const char* field) {
    std::string f = field ? field : "";
    if (f == "socks") return "SOCKS5 proxy";
    if (f == "pac") return "PAC file";
    if (f == "http") return "HTTP proxy";
    return "local proxy";
}

} // namespace

std::string DescribeRpcError(json_t* error) {
    const char* code = json_string_value(json_object_get(error, "code"));
    std::string c = code ? code : "";
    const char* field = json_string_value(json_object_get(error, "field"));
    if (c == "invalid_port") return "The " + ListenerName(field) + " port must be between 1 and 65535.";
    if (c == "duplicate_port") {
        json_t* fields = json_object_get(error, "fields");
        return "The " + ListenerName(json_string_value(json_array_get(fields, 0))) + " and " +
               ListenerName(json_string_value(json_array_get(fields, 1))) + " can't use the same port.";
    }
    if (c == "port_unavailable")
        return "The " + ListenerName(field) + " port is already in use by another program.";
    if (c == "storage_failed")
        return "winTails couldn't save its files, so nothing was changed. Check that there's free disk space and try "
               "again.";
    if (c == "network_not_found") return "That tailnet no longer exists.";
    if (c == "invalid_state") return "That action isn't available in the tailnet's current state.";
    if (c == "already_running") return "winTails is already running.";
    if (c == "invalid_args") {
        // A wintails bug, but the field narrows it down for a bug report.
        return std::string("Something went wrong in winTails (invalid_args") + (field ? std::string(": ") + field : "") +
               ").";
    }
    // invalid_request, unknown_command (wintails bugs), internal, or a code
    // this build doesn't know yet: nothing the user can act on beyond trying
    // again.
    return "Something went wrong in winTails (" + (c.empty() ? std::string("unknown error") : c) + ").";
}

void RpcClient::HandleLine(std::string* linePtr) {
    std::string line = std::move(*linePtr);
    delete linePtr;

    json_error_t error{};
    json_t* root = json_loads(line.c_str(), 0, &error);
    if (!root) return; // malformed line from the child; nothing sane to do

    const char* type = json_string_value(json_object_get(root, "type"));
    if (type && std::string(type) == "res") {
        json_t* idValue = json_object_get(root, "id");
        if (!json_is_integer(idValue)) {
            // No readable id: can't match a callback. Only a malformed Send
            // can cause this.
            OutputDebugStringA(("wintails: response with no id: " + line + "\n").c_str());
            json_decref(root);
            return;
        }
        int id = static_cast<int>(json_integer_value(idValue));
        auto it = pending_.find(id);
        if (it != pending_.end()) {
            bool ok = json_is_true(json_object_get(root, "ok"));
            json_t* data = json_object_get(root, "data");
            it->second(ok, data, ok ? "" : DescribeRpcError(json_object_get(root, "error")));
            pending_.erase(it);
        }
    } else if (type && std::string(type) == "event") {
        const char* name = json_string_value(json_object_get(root, "name"));
        if (name && onEvent_) {
            onEvent_(name, json_object_get(root, "data"));
        }
    }

    json_decref(root);
}

void RpcClient::Stop() {
    if (!childProcess_) return;

    Send("quit", nullptr, [](bool, json_t*, const std::string&) {});
    // quit waits up to ~20s for a logout in flight (docs/rpc-protocol.md);
    // killing early would skip telling the control server.
    WaitForSingleObject(childProcess_, 30000);
    TerminateProcess(childProcess_, 0); // no-op if it already exited cleanly

    CloseHandle(childProcess_);
    childProcess_ = nullptr;
    if (stdinWrite_) { CloseHandle(stdinWrite_); stdinWrite_ = nullptr; }

    if (readerThread_) {
        WaitForSingleObject(readerThread_, 2000);
        CloseHandle(readerThread_);
        readerThread_ = nullptr;
    }
    if (stdoutRead_) { CloseHandle(stdoutRead_); stdoutRead_ = nullptr; }

    if (stderrReaderThread_) {
        WaitForSingleObject(stderrReaderThread_, 2000);
        CloseHandle(stderrReaderThread_);
        stderrReaderThread_ = nullptr;
    }
    if (stderrRead_) { CloseHandle(stderrRead_); stderrRead_ = nullptr; }
}
