// Windows couch-co-op app. Join a GBear host, or host so a Mac can join.
// Speaks gbear-stream/1: HTTP pair + stream/start, TCP GBV1 video, TCP GBA1 audio, UDP GBG1 pads.
// A pasted remote co-op invite (`GBEAR1 <code> <https address>`) joins through the host's relay instead:
// the same packets arrive wrapped in GBTL frames on one WebSocket.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define INITGUID

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <winhttp.h>
#include <mmsystem.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <mferror.h>
#include <xinput.h>
#include <objidl.h>
#include <commctrl.h>
#include <dwmapi.h>
#include <uxtheme.h>

#include "GBearWinHost.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <deque>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <algorithm>
using std::max;
using std::min;
#include <gdiplus.h>

#pragma comment(lib, "winhttp.lib")
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "winmm.lib")
#pragma comment(lib, "xinput.lib")
#pragma comment(lib, "gdi32.lib")

namespace {

constexpr uint16_t kControlPort = 28765;
constexpr uint16_t kVideoPort = 28766;
constexpr uint16_t kAudioPort = 28769;
constexpr uint16_t kInputPort = 28768;
constexpr uint32_t kVideoMagic = 0x31564247;  // GBV1
constexpr uint32_t kAudioMagic = 0x31414247;  // GBA1
constexpr uint32_t kGamepadMagic = 0x31474247;  // GBG1
constexpr int kVideoHeader = 13;
constexpr int kAudioHeader = 11;
constexpr uint32_t kTunnelMagic = 0x4C544247;  // GBTL
constexpr int kTunnelHeader = 9;
constexpr uint8_t kChannelControl = 1;
constexpr uint8_t kChannelVideo = 2;
constexpr uint8_t kChannelAudio = 3;
constexpr uint8_t kChannelInput = 4;

constexpr UINT WM_APP_STATUS = WM_APP + 1;
constexpr UINT WM_APP_FRAME = WM_APP + 2;
constexpr UINT WM_APP_PHASE = WM_APP + 3;
constexpr UINT WM_APP_PAIR = WM_APP + 4;

constexpr int IDC_HOST = 101;
constexpr int IDC_SEAT = 102;
constexpr int IDC_JOIN = 103;
constexpr int IDC_HOST_BTN = 105;
constexpr int IDC_PAIR = 106;

// Same palette as the companion app (companion_theme.dart).
namespace ui {
constexpr COLORREF kBackground = RGB(0x0E, 0x10, 0x14);
constexpr COLORREF kSurface = RGB(0x16, 0x19, 0x20);
constexpr COLORREF kCard = RGB(0x1C, 0x20, 0x28);
constexpr COLORREF kField = RGB(0x23, 0x28, 0x33);
constexpr COLORREF kOutline = RGB(0x2C, 0x32, 0x3D);
constexpr COLORREF kFieldOutline = RGB(0x3A, 0x42, 0x50);
constexpr COLORREF kPrimary = RGB(0x6E, 0xB5, 0xFF);
constexpr COLORREF kText = RGB(0xE6, 0xE9, 0xEF);
constexpr COLORREF kTextSecondary = RGB(0xA3, 0xAB, 0xB8);
constexpr COLORREF kTextTertiary = RGB(0x6F, 0x78, 0x86);
constexpr COLORREF kDanger = RGB(0xEF, 0x6B, 0x62);
constexpr COLORREF kSuccess = RGB(0x5B, 0xD3, 0x7A);
constexpr COLORREF kWaiting = RGB(0xF2, 0xC1, 0x4E);

Gdiplus::Color color(COLORREF c, BYTE alpha = 255) {
    return Gdiplus::Color(alpha, GetRValue(c), GetGValue(c), GetBValue(c));
}

// `t` of `over` on top of `base`.
COLORREF blend(COLORREF base, COLORREF over, float t) {
    auto mix = [t](int a, int b) { return (BYTE)std::lround(a + (b - a) * t); };
    return RGB(mix(GetRValue(base), GetRValue(over)), mix(GetGValue(base), GetGValue(over)), mix(GetBValue(base), GetBValue(over)));
}

void roundedPath(Gdiplus::GraphicsPath& path, float x, float y, float w, float h, float radius) {
    float d = std::min(radius * 2, std::min(w, h));
    path.AddArc(x, y, d, d, 180, 90);
    path.AddArc(x + w - d, y, d, d, 270, 90);
    path.AddArc(x + w - d, y + h - d, d, d, 0, 90);
    path.AddArc(x, y + h - d, d, d, 90, 90);
    path.CloseFigure();
}

void fillRounded(Gdiplus::Graphics& g, float x, float y, float w, float h, float radius, COLORREF fill, BYTE alpha = 255) {
    Gdiplus::GraphicsPath path;
    roundedPath(path, x, y, w, h, radius);
    Gdiplus::SolidBrush brush(color(fill, alpha));
    g.FillPath(&brush, &path);
}

void strokeRounded(Gdiplus::Graphics& g, float x, float y, float w, float h, float radius, COLORREF stroke, float width, BYTE alpha = 255) {
    Gdiplus::GraphicsPath path;
    roundedPath(path, x + width / 2, y + width / 2, w - width, h - width, radius);
    Gdiplus::Pen pen(color(stroke, alpha), width);
    g.DrawPath(&pen, &path);
}

void drawText(HDC dc, HFONT font, COLORREF c, const std::wstring& text, RECT r, UINT format) {
    HGDIOBJ old = SelectObject(dc, font);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, c);
    DrawTextW(dc, text.c_str(), (int)text.size(), &r, format | DT_NOPREFIX);
    SelectObject(dc, old);
}

int textWidth(HDC dc, HFONT font, const std::wstring& text) {
    HGDIOBJ old = SelectObject(dc, font);
    SIZE size{};
    GetTextExtentPoint32W(dc, text.c_str(), (int)text.size(), &size);
    SelectObject(dc, old);
    return size.cx;
}
}  // namespace ui

enum Button : uint32_t {
    kA = 1u << 0,
    kB = 1u << 1,
    kX = 1u << 2,
    kY = 1u << 3,
    kL1 = 1u << 4,
    kR1 = 1u << 5,
    kL3 = 1u << 6,
    kR3 = 1u << 7,
    kStart = 1u << 8,
    kSelect = 1u << 9,
    kUp = 1u << 10,
    kDown = 1u << 11,
    kLeft = 1u << 12,
    kRight = 1u << 13,
};

struct PadState {
    uint32_t buttons = 0;
    float lx = 0, ly = 0, rx = 0, ry = 0, lt = 0, rt = 0;
    bool operator==(const PadState& o) const {
        return buttons == o.buttons && lx == o.lx && ly == o.ly && rx == o.rx && ry == o.ry && lt == o.lt && rt == o.rt;
    }
};

std::mutex gLogMu;
std::wstring gLogPath;

void logLine(const std::string& line) {
    std::lock_guard<std::mutex> lock(gLogMu);
    if (gLogPath.empty()) return;
    HANDLE file = CreateFileW(gLogPath.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    SYSTEMTIME st;
    GetLocalTime(&st);
    char prefix[64];
    snprintf(prefix, sizeof(prefix), "%04u-%02u-%02u %02u:%02u:%02u ", st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
    DWORD wrote = 0;
    WriteFile(file, prefix, (DWORD)strlen(prefix), &wrote, nullptr);
    WriteFile(file, line.data(), (DWORD)line.size(), &wrote, nullptr);
    WriteFile(file, "\r\n", 2, &wrote, nullptr);
    CloseHandle(file);
}

std::wstring utf8ToWide(const std::string& s) {
    if (s.empty()) return L"";
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring out(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), out.data(), n);
    return out;
}

std::string wideToUtf8(const std::wstring& s) {
    if (s.empty()) return "";
    int n = WideCharToMultiByte(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0, nullptr, nullptr);
    std::string out(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, s.data(), (int)s.size(), out.data(), n, nullptr, nullptr);
    return out;
}

std::string jsonEscape(const std::string& s) {
    std::string out;
    out.reserve(s.size());
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') out.push_back('\\');
        if (c >= 32) out.push_back((char)c);
    }
    return out;
}

int jsonInt(const std::string& body, const char* key, int fallback) {
    std::string pat = std::string("\"") + key + "\":";
    auto pos = body.find(pat);
    if (pos == std::string::npos) return fallback;
    pos += pat.size();
    while (pos < body.size() && (body[pos] == ' ' || body[pos] == '\t')) pos++;
    return atoi(body.c_str() + pos);
}

std::string jsonString(const std::string& body, const char* key) {
    std::string pat = std::string("\"") + key + "\"";
    auto pos = body.find(pat);
    if (pos == std::string::npos) return "";
    pos += pat.size();
    while (pos < body.size() && (body[pos] == ' ' || body[pos] == ':')) pos++;
    if (pos >= body.size() || body[pos] != '"') return "";
    pos++;
    std::string out;
    while (pos < body.size() && body[pos] != '"') {
        out.push_back(body[pos]);
        pos++;
    }
    return out;
}

bool jsonOk(const std::string& body) {
    return body.find("\"ok\":true") != std::string::npos || body.find("\"ok\": true") != std::string::npos;
}

// The value's text as written (number, string with quotes, ...), for echoing it back unchanged.
std::string jsonRaw(const std::string& body, const char* key) {
    std::string pat = std::string("\"") + key + "\"";
    auto pos = body.find(pat);
    if (pos == std::string::npos) return "";
    pos += pat.size();
    while (pos < body.size() && (body[pos] == ' ' || body[pos] == ':')) pos++;
    size_t end = pos;
    if (end < body.size() && body[end] == '"') {
        end = body.find('"', end + 1);
        return end == std::string::npos ? "" : body.substr(pos, end - pos + 1);
    }
    while (end < body.size() && body[end] != ',' && body[end] != '}' && body[end] != ' ') end++;
    return body.substr(pos, end - pos);
}

struct HttpResult {
    int status = 0;
    std::string body;
    std::string error;
};

HttpResult httpCall(
    const std::wstring& host,
    INTERNET_PORT port,
    bool secure,
    const wchar_t* method,
    const std::wstring& path,
    const std::string& body,
    const std::wstring& extraHeaders,
    int timeoutMs
) {
    HttpResult result;
    // Remote co-op invites go through the internet, so they honor the system proxy; LAN hosts never do.
    HINTERNET session = WinHttpOpen(
        L"GBearGuest/1",
        secure ? WINHTTP_ACCESS_TYPE_DEFAULT_PROXY : WINHTTP_ACCESS_TYPE_NO_PROXY,
        WINHTTP_NO_PROXY_NAME,
        WINHTTP_NO_PROXY_BYPASS,
        0
    );
    if (!session) {
        result.error = "WinHTTP open failed";
        return result;
    }
    HINTERNET connect = WinHttpConnect(session, host.c_str(), port, 0);
    if (!connect) {
        result.error = "connect";
        WinHttpCloseHandle(session);
        return result;
    }
    HINTERNET request = WinHttpOpenRequest(
        connect, method, path.c_str(), nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, secure ? WINHTTP_FLAG_SECURE : 0
    );
    if (!request) {
        result.error = "Could not open HTTP request";
        WinHttpCloseHandle(connect);
        WinHttpCloseHandle(session);
        return result;
    }
    WinHttpSetTimeouts(request, timeoutMs, timeoutMs, timeoutMs * 2, timeoutMs * 2);
    std::wstring headers = extraHeaders;
    if (!body.empty()) headers += L"Content-Type: application/json\r\n";
    BOOL ok = WinHttpSendRequest(
        request,
        headers.empty() ? WINHTTP_NO_ADDITIONAL_HEADERS : headers.c_str(),
        headers.empty() ? 0 : (DWORD)-1,
        body.empty() ? WINHTTP_NO_REQUEST_DATA : (LPVOID)body.data(),
        (DWORD)body.size(),
        (DWORD)body.size(),
        0
    );
    if (!ok || !WinHttpReceiveResponse(request, nullptr)) {
        result.error = "no answer";
        WinHttpCloseHandle(request);
        WinHttpCloseHandle(connect);
        WinHttpCloseHandle(session);
        return result;
    }
    DWORD status = 0;
    DWORD statusSize = sizeof(status);
    WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &status, &statusSize, WINHTTP_NO_HEADER_INDEX);
    result.status = (int)status;
    for (;;) {
        DWORD available = 0;
        if (!WinHttpQueryDataAvailable(request, &available) || available == 0) break;
        std::string chunk(available, '\0');
        DWORD read = 0;
        if (!WinHttpReadData(request, chunk.data(), available, &read)) break;
        chunk.resize(read);
        result.body += chunk;
    }
    WinHttpCloseHandle(request);
    WinHttpCloseHandle(connect);
    WinHttpCloseHandle(session);
    return result;
}

HttpResult httpRequest(const std::wstring& host, const wchar_t* method, const std::wstring& path, const std::string& body) {
    HttpResult result = httpCall(host, kControlPort, false, method, path, body, L"", 4000);
    if (result.error == "connect") {
        result.error = "Could not connect to host on port 28765";
    } else if (result.error == "no answer") {
        result.error = "Host did not answer on port 28765. Is GBear open to the Streaming tab, and is the Mac firewall allowing it?";
    }
    return result;
}

struct RemoteInvite {
    std::string code;
    std::wstring host;
    INTERNET_PORT port = 0;
    bool secure = true;
};

bool looksLikeInvite(const std::wstring& raw) {
    std::wstring upper = raw;
    for (auto& c : upper) c = towupper(c);
    return upper.find(L"GBEAR1") != std::wstring::npos || upper.find(L"://") != std::wstring::npos;
}

// Accepts the whole `GBEAR1 <code> <address>` line, or `<code> <address>`. Chat apps wrap the long
// address at hyphens, and the address never has spaces, so everything after the code is joined back up.
bool parseInvite(const std::wstring& raw, RemoteInvite& out) {
    std::vector<std::wstring> parts;
    std::wstring current;
    for (wchar_t c : raw) {
        if (c == 0x200B || c == 0x200C || c == 0x200D || c == 0x2060 || c == 0xFEFF || c == 0x00AD) continue;
        if (iswspace(c)) {
            if (!current.empty()) parts.push_back(current);
            current.clear();
        } else {
            current.push_back(c);
        }
    }
    if (!current.empty()) parts.push_back(current);
    size_t first = 0;
    if (parts.size() >= 3) {
        std::wstring tag = parts[0];
        for (auto& c : tag) c = towupper(c);
        if (tag == L"GBEAR1") first = 1;
    }
    if (parts.size() < first + 2 || parts[first + 1].find(L"://") == std::wstring::npos) return false;
    std::wstring code = parts[first];
    for (auto& c : code) c = towupper(c);
    std::wstring address;
    for (size_t i = first + 1; i < parts.size(); i++) address += parts[i];
    while (!address.empty() && address.back() == L'/') address.pop_back();

    URL_COMPONENTS url{};
    url.dwStructSize = sizeof(url);
    wchar_t hostName[256] = L"";
    url.lpszHostName = hostName;
    url.dwHostNameLength = 256;
    url.dwUrlPathLength = (DWORD)-1;
    url.dwSchemeLength = (DWORD)-1;
    if (!WinHttpCrackUrl(address.c_str(), 0, 0, &url) || hostName[0] == 0) return false;
    if (url.nScheme != INTERNET_SCHEME_HTTPS && url.nScheme != INTERNET_SCHEME_HTTP) return false;
    out.code = wideToUtf8(code);
    out.host = hostName;
    out.port = url.nPort;
    out.secure = url.nScheme == INTERNET_SCHEME_HTTPS;
    return !out.code.empty();
}

std::wstring urlEncode(const std::string& text) {
    std::wstring out;
    const char* hex = "0123456789ABCDEF";
    for (unsigned char c : text) {
        if (isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') {
            out.push_back((wchar_t)c);
        } else {
            out.push_back(L'%');
            out.push_back((wchar_t)hex[c >> 4]);
            out.push_back((wchar_t)hex[c & 15]);
        }
    }
    return out;
}

std::vector<uint8_t> tunnelFrame(uint8_t channel, const void* payload, size_t length) {
    std::vector<uint8_t> frame(kTunnelHeader + length);
    uint32_t magic = kTunnelMagic;
    uint32_t size = (uint32_t)length;
    memcpy(frame.data(), &magic, 4);
    frame[4] = channel;
    memcpy(frame.data() + 5, &size, 4);
    if (length) memcpy(frame.data() + kTunnelHeader, payload, length);
    return frame;
}

// One WebSocket to the host's relay. WinHTTP allows one send and one receive at a time, so sends
// from the receive thread (pong, hello) and the controller thread share a lock.
class RelaySocket {
public:
    ~RelaySocket() {
        abort();
        if (connect) WinHttpCloseHandle(connect);
        if (session) WinHttpCloseHandle(session);
    }

    bool open(const RemoteInvite& invite, const std::wstring& path, std::string& error) {
        session = WinHttpOpen(L"GBearGuest/1", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
        connect = session ? WinHttpConnect(session, invite.host.c_str(), invite.port, 0) : nullptr;
        if (!connect) {
            error = "could not connect";
            return false;
        }
        HINTERNET opened = WinHttpOpenRequest(
            connect, L"GET", path.c_str(), nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, invite.secure ? WINHTTP_FLAG_SECURE : 0
        );
        if (!opened) {
            error = "could not open request";
            return false;
        }
        {
            std::lock_guard<std::mutex> lock(mu);
            if (aborted) {
                WinHttpCloseHandle(opened);
                error = "left";
                return false;
            }
            request = opened;
        }
        // Receives time out if the relay goes quiet; the host pings every second once we are seated.
        WinHttpSetTimeouts(opened, 10000, 15000, 15000, 20000);
        bool answered = WinHttpSetOption(opened, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, nullptr, 0) &&
                        WinHttpSendRequest(opened, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) &&
                        WinHttpReceiveResponse(opened, nullptr);
        DWORD failure = answered ? 0 : GetLastError();
        DWORD status = 0;
        DWORD statusSize = sizeof(status);
        if (answered) {
            WinHttpQueryHeaders(opened, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &status, &statusSize, WINHTTP_NO_HEADER_INDEX);
        }
        HINTERNET upgraded = (answered && status == 101) ? WinHttpWebSocketCompleteUpgrade(opened, 0) : nullptr;
        std::lock_guard<std::mutex> lock(mu);
        if (request) {
            WinHttpCloseHandle(request);
            request = nullptr;
        }
        if (aborted) {
            if (upgraded) WinHttpCloseHandle(upgraded);
            error = "left";
            return false;
        }
        if (!upgraded) {
            error = answered ? "the relay answered HTTP " + std::to_string(status) : "no answer (error " + std::to_string(failure) + ")";
            return false;
        }
        socket = upgraded;
        return true;
    }

    bool send(const std::vector<uint8_t>& frame) {
        std::lock_guard<std::mutex> lock(mu);
        if (!socket) return false;
        return WinHttpWebSocketSend(socket, WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE, (PVOID)frame.data(), (DWORD)frame.size()) == ERROR_SUCCESS;
    }

    // One whole message. False when the socket closed, failed, or timed out.
    bool receive(std::vector<uint8_t>& message, bool& text) {
        message.clear();
        HINTERNET current;
        {
            std::lock_guard<std::mutex> lock(mu);
            current = socket;
        }
        if (!current) return false;
        for (;;) {
            DWORD read = 0;
            WINHTTP_WEB_SOCKET_BUFFER_TYPE type{};
            if (WinHttpWebSocketReceive(current, chunk, sizeof(chunk), &read, &type) != ERROR_SUCCESS) return false;
            if (type == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE) return false;
            message.insert(message.end(), chunk, chunk + read);
            if (message.size() > 16 * 1024 * 1024) return false;
            if (type == WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE || type == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE) {
                text = type == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE;
                return true;
            }
        }
    }

    // Safe from any thread: a handshake or receive in progress returns false.
    void abort() {
        std::lock_guard<std::mutex> lock(mu);
        aborted = true;
        if (request) {
            WinHttpCloseHandle(request);
            request = nullptr;
        }
        if (socket) {
            WinHttpCloseHandle(socket);
            socket = nullptr;
        }
    }

private:
    std::mutex mu;
    bool aborted = false;
    HINTERNET session = nullptr;
    HINTERNET connect = nullptr;
    HINTERNET request = nullptr;
    HINTERNET socket = nullptr;
    uint8_t chunk[65536];
};

std::wstring appDataDir() {
    wchar_t* env = _wgetenv(L"APPDATA");
    std::wstring dir = env ? std::wstring(env) + L"\\GBear" : L".";
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir;
}

std::string loadOrCreateDeviceId() {
    std::wstring path = appDataDir() + L"\\windows-guest-id.txt";
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file != INVALID_HANDLE_VALUE) {
        char buf[80] = {};
        DWORD read = 0;
        ReadFile(file, buf, sizeof(buf) - 1, &read, nullptr);
        CloseHandle(file);
        std::string id(buf, read);
        while (!id.empty() && (id.back() == '\n' || id.back() == '\r' || id.back() == ' ')) id.pop_back();
        if (!id.empty()) return id;
    }
    GUID guid;
    CoCreateGuid(&guid);
    wchar_t text[64];
    StringFromGUID2(guid, text, 64);
    std::string id = wideToUtf8(text);
    if (!id.empty() && id.front() == '{') id.erase(id.begin());
    if (!id.empty() && id.back() == '}') id.pop_back();
    file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file != INVALID_HANDLE_VALUE) {
        DWORD wrote = 0;
        WriteFile(file, id.data(), (DWORD)id.size(), &wrote, nullptr);
        CloseHandle(file);
    }
    return id;
}

std::string deviceName() {
    wchar_t name[256];
    DWORD size = 256;
    if (!GetComputerNameW(name, &size)) return "Windows (computer)";
    return wideToUtf8(name) + " (Windows)";
}

bool recvExact(SOCKET sock, void* dst, int count, const std::atomic<bool>& stop) {
    char* p = static_cast<char*>(dst);
    int got = 0;
    while (got < count && !stop.load()) {
        int n = recv(sock, p + got, count - got, 0);
        if (n <= 0) return false;
        got += n;
    }
    return got == count && !stop.load();
}

SOCKET connectTCP(const std::string& host, uint16_t port) {
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    addrinfo* info = nullptr;
    std::string portText = std::to_string(port);
    if (getaddrinfo(host.c_str(), portText.c_str(), &hints, &info) != 0) return INVALID_SOCKET;
    SOCKET sock = INVALID_SOCKET;
    for (addrinfo* it = info; it; it = it->ai_next) {
        sock = socket(it->ai_family, it->ai_socktype, it->ai_protocol);
        if (sock == INVALID_SOCKET) continue;
        DWORD timeout = 2000;
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (char*)&timeout, sizeof(timeout));
        if (connect(sock, it->ai_addr, (int)it->ai_addrlen) == 0) break;
        closesocket(sock);
        sock = INVALID_SOCKET;
    }
    freeaddrinfo(info);
    return sock;
}

uint8_t clipByte(int v) {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return (uint8_t)v;
}

void nv12ToBGRA(const uint8_t* src, int stride, int width, int height, std::vector<uint8_t>& dst) {
    int pitch = stride < 0 ? -stride : stride;
    dst.resize((size_t)width * height * 4);
    const uint8_t* yPlane = src;
    const uint8_t* uvPlane = src + pitch * height;
    for (int y = 0; y < height; y++) {
        const uint8_t* yRow = yPlane + y * pitch;
        const uint8_t* uvRow = uvPlane + (y / 2) * pitch;
        uint8_t* out = dst.data() + (size_t)y * width * 4;
        for (int x = 0; x < width; x++) {
            int C = (int)yRow[x] - 16;
            int D = (int)uvRow[(x & ~1)] - 128;
            int E = (int)uvRow[(x & ~1) + 1] - 128;
            out[0] = clipByte((298 * C + 516 * D + 128) >> 8);
            out[1] = clipByte((298 * C - 100 * D - 208 * E + 128) >> 8);
            out[2] = clipByte((298 * C + 409 * E + 128) >> 8);
            out[3] = 255;
            out += 4;
        }
    }
}

void copyRGB32(const uint8_t* src, int stride, int width, int height, std::vector<uint8_t>& dst) {
    int pitch = stride < 0 ? -stride : stride;
    if (pitch < width * 4) pitch = width * 4;
    dst.resize((size_t)width * height * 4);
    bool bottomUp = stride < 0;
    for (int y = 0; y < height; y++) {
        int srcY = bottomUp ? (height - 1 - y) : y;
        memcpy(dst.data() + (size_t)y * width * 4, src + srcY * pitch, (size_t)width * 4);
    }
}

class H264Decoder {
public:
    ~H264Decoder() { reset(); }

    void reset() {
        if (mft) {
            mft->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
            mft->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
            mft->Release();
            mft = nullptr;
        }
        width = 0;
        height = 0;
        nv12 = false;
        stride = 0;
        pts = 0;
    }

    bool ensure(int w, int h) {
        if (mft && width == w && height == h) return true;
        reset();
        MFT_REGISTER_TYPE_INFO inInfo{MFMediaType_Video, MFVideoFormat_H264};
        IMFActivate** activates = nullptr;
        UINT32 count = 0;
        HRESULT hr = MFTEnumEx(
            MFT_CATEGORY_VIDEO_DECODER,
            MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_SORTANDFILTER,
            &inInfo,
            nullptr,
            &activates,
            &count
        );
        if (FAILED(hr) || count == 0) {
            logLine("No Windows H.264 decoder");
            return false;
        }
        hr = activates[0]->ActivateObject(IID_PPV_ARGS(&mft));
        for (UINT32 i = 0; i < count; i++) activates[i]->Release();
        CoTaskMemFree(activates);
        if (FAILED(hr) || !mft) {
            logLine("H.264 decoder activate failed");
            return false;
        }
        IMFAttributes* attrs = nullptr;
        if (SUCCEEDED(mft->QueryInterface(IID_PPV_ARGS(&attrs)))) {
            attrs->SetUINT32(MF_LOW_LATENCY, TRUE);
            attrs->Release();
        }
        IMFMediaType* inType = nullptr;
        MFCreateMediaType(&inType);
        inType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        inType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
        inType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        MFSetAttributeSize(inType, MF_MT_FRAME_SIZE, (UINT32)w, (UINT32)h);
        MFSetAttributeRatio(inType, MF_MT_FRAME_RATE, 60, 1);
        hr = mft->SetInputType(0, inType, 0);
        inType->Release();
        if (FAILED(hr)) {
            char buf[80];
            snprintf(buf, sizeof(buf), "SetInputType failed 0x%08lx", (unsigned long)hr);
            logLine(buf);
            reset();
            return false;
        }
        if (!selectOutput()) {
            reset();
            return false;
        }
        mft->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
        mft->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
        mft->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
        width = w;
        height = h;
        logLine("H.264 decoder ready " + std::to_string(w) + "x" + std::to_string(h) + (nv12 ? " NV12" : " RGB32"));
        return true;
    }

    bool decode(const uint8_t* annexB, uint32_t length, bool keyframe, std::vector<uint8_t>& bgra, int& outW, int& outH) {
        if (!mft || length == 0) return false;
        IMFMediaBuffer* buffer = nullptr;
        if (FAILED(MFCreateMemoryBuffer(length, &buffer))) return false;
        BYTE* dest = nullptr;
        if (FAILED(buffer->Lock(&dest, nullptr, nullptr))) {
            buffer->Release();
            return false;
        }
        memcpy(dest, annexB, length);
        buffer->Unlock();
        buffer->SetCurrentLength(length);
        IMFSample* sample = nullptr;
        MFCreateSample(&sample);
        sample->AddBuffer(buffer);
        buffer->Release();
        sample->SetSampleTime(pts);
        sample->SetSampleDuration(166667);
        sample->SetUINT32(MFSampleExtension_CleanPoint, keyframe ? TRUE : FALSE);
        pts += 166667;

        HRESULT hr = mft->ProcessInput(0, sample, 0);
        sample->Release();
        if (hr == MF_E_NOTACCEPTING) {
            drain(bgra, outW, outH);
            IMFMediaBuffer* retryBuf = nullptr;
            MFCreateMemoryBuffer(length, &retryBuf);
            BYTE* retryDest = nullptr;
            retryBuf->Lock(&retryDest, nullptr, nullptr);
            memcpy(retryDest, annexB, length);
            retryBuf->Unlock();
            retryBuf->SetCurrentLength(length);
            IMFSample* retry = nullptr;
            MFCreateSample(&retry);
            retry->AddBuffer(retryBuf);
            retryBuf->Release();
            retry->SetSampleTime(pts);
            retry->SetUINT32(MFSampleExtension_CleanPoint, keyframe ? TRUE : FALSE);
            hr = mft->ProcessInput(0, retry, 0);
            retry->Release();
        }
        if (FAILED(hr)) return false;
        return drain(bgra, outW, outH);
    }

private:
    bool selectOutput() {
        for (DWORD i = 0;; i++) {
            IMFMediaType* type = nullptr;
            HRESULT hr = mft->GetOutputAvailableType(0, i, &type);
            if (FAILED(hr)) break;
            GUID subtype{};
            type->GetGUID(MF_MT_SUBTYPE, &subtype);
            bool rgb = IsEqualGUID(subtype, MFVideoFormat_RGB32);
            bool yuv = IsEqualGUID(subtype, MFVideoFormat_NV12);
            if (!rgb && !yuv) {
                type->Release();
                continue;
            }
            hr = mft->SetOutputType(0, type, 0);
            if (SUCCEEDED(hr)) {
                nv12 = yuv;
                UINT32 rawStride = 0;
                if (SUCCEEDED(type->GetUINT32(MF_MT_DEFAULT_STRIDE, &rawStride))) stride = (INT32)rawStride;
                type->Release();
                return true;
            }
            type->Release();
        }
        logLine("H.264 decoder has no RGB32 or NV12 output");
        return false;
    }

    bool drain(std::vector<uint8_t>& bgra, int& outW, int& outH) {
        bool produced = false;
        for (int n = 0; n < 8; n++) {
            MFT_OUTPUT_STREAM_INFO info{};
            mft->GetOutputStreamInfo(0, &info);
            MFT_OUTPUT_DATA_BUFFER out{};
            out.dwStreamID = 0;
            IMFSample* sample = nullptr;
            IMFMediaBuffer* buffer = nullptr;
            bool weOwn = (info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) == 0;
            if (weOwn) {
                DWORD size = info.cbSize ? info.cbSize : (DWORD)(width * height * 4);
                MFCreateSample(&sample);
                MFCreateMemoryBuffer(size, &buffer);
                sample->AddBuffer(buffer);
                out.pSample = sample;
            }
            DWORD status = 0;
            HRESULT hr = mft->ProcessOutput(0, 1, &out, &status);
            if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) {
                if (sample) sample->Release();
                if (buffer) buffer->Release();
                break;
            }
            if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
                if (sample) sample->Release();
                if (buffer) buffer->Release();
                selectOutput();
                continue;
            }
            if (FAILED(hr) || !out.pSample) {
                if (sample) sample->Release();
                if (buffer) buffer->Release();
                break;
            }
            IMFMediaBuffer* locked = nullptr;
            out.pSample->ConvertToContiguousBuffer(&locked);
            BYTE* data = nullptr;
            DWORD current = 0;
            if (locked && SUCCEEDED(locked->Lock(&data, nullptr, &current)) && data && width > 0 && height > 0) {
                if (nv12) nv12ToBGRA(data, stride == 0 ? width : stride, width, height, bgra);
                else copyRGB32(data, stride == 0 ? width * 4 : stride, width, height, bgra);
                locked->Unlock();
                outW = width;
                outH = height;
                produced = !bgra.empty();
            }
            if (locked) locked->Release();
            if (out.pEvents) out.pEvents->Release();
            if (sample) sample->Release();
            else if (out.pSample && !weOwn) out.pSample->Release();
            if (buffer) buffer->Release();
        }
        return produced;
    }

    IMFTransform* mft = nullptr;
    int width = 0;
    int height = 0;
    INT32 stride = 0;
    bool nv12 = false;
    LONGLONG pts = 0;
};

class AudioPlayer {
public:
    void stop() {
        if (!wave) return;
        waveOutReset(wave);
        for (auto& slot : slots) {
            if (slot.prepared) {
                waveOutUnprepareHeader(wave, &slot.header, sizeof(WAVEHDR));
                slot.prepared = false;
            }
        }
        waveOutClose(wave);
        wave = nullptr;
        rate = 0;
        channels = 0;
    }

    void play(const uint8_t* pcm, int bytes, int sampleRate, int ch) {
        if (bytes <= 0 || sampleRate <= 0 || ch <= 0) return;
        if (!wave || rate != sampleRate || channels != ch) open(sampleRate, ch);
        if (!wave) return;
        Slot* slot = nullptr;
        for (auto& candidate : slots) {
            if (!candidate.inUse) {
                slot = &candidate;
                break;
            }
        }
        if (!slot) return;
        if (slot->prepared) {
            waveOutUnprepareHeader(wave, &slot->header, sizeof(WAVEHDR));
            slot->prepared = false;
        }
        if ((int)slot->bytes.size() < bytes) slot->bytes.resize(bytes);
        memcpy(slot->bytes.data(), pcm, bytes);
        slot->header.lpData = (LPSTR)slot->bytes.data();
        slot->header.dwBufferLength = bytes;
        slot->header.dwFlags = 0;
        slot->header.dwUser = (DWORD_PTR)slot;
        if (waveOutPrepareHeader(wave, &slot->header, sizeof(WAVEHDR)) != MMSYSERR_NOERROR) return;
        slot->prepared = true;
        slot->inUse = true;
        if (waveOutWrite(wave, &slot->header, sizeof(WAVEHDR)) != MMSYSERR_NOERROR) slot->inUse = false;
    }

private:
    struct Slot {
        WAVEHDR header{};
        std::vector<uint8_t> bytes;
        bool prepared = false;
        bool inUse = false;
    };

    static void CALLBACK done(HWAVEOUT, UINT msg, DWORD_PTR, DWORD_PTR param, DWORD_PTR) {
        if (msg != WOM_DONE) return;
        auto* header = reinterpret_cast<WAVEHDR*>(param);
        auto* slot = reinterpret_cast<Slot*>(header->dwUser);
        if (slot) slot->inUse = false;
    }

    void open(int sampleRate, int ch) {
        stop();
        WAVEFORMATEX fmt{};
        fmt.wFormatTag = WAVE_FORMAT_PCM;
        fmt.nChannels = (WORD)ch;
        fmt.nSamplesPerSec = sampleRate;
        fmt.wBitsPerSample = 16;
        fmt.nBlockAlign = (WORD)(ch * 2);
        fmt.nAvgBytesPerSec = sampleRate * fmt.nBlockAlign;
        if (waveOutOpen(&wave, WAVE_MAPPER, &fmt, (DWORD_PTR)done, 0, CALLBACK_FUNCTION) != MMSYSERR_NOERROR) {
            wave = nullptr;
            logLine("waveOutOpen failed");
            return;
        }
        rate = sampleRate;
        channels = ch;
    }

    HWAVEOUT wave = nullptr;
    int rate = 0;
    int channels = 0;
    Slot slots[6];
};

class GuestApp {
public:
    HINSTANCE instance = nullptr;
    HWND hwnd = nullptr;
    HWND hostEdit = nullptr;
    HWND seatCombo = nullptr;
    HWND joinButton = nullptr;
    HWND hostButton = nullptr;
    HWND pairButton = nullptr;
    double scale = 1.0;
    HFONT titleFont = nullptr;
    HFONT bodyFont = nullptr;
    HFONT buttonFont = nullptr;
    HFONT smallFont = nullptr;
    HFONT headlineFont = nullptr;
    HBRUSH backgroundBrush = nullptr;
    HBRUSH surfaceBrush = nullptr;
    HBRUSH cardBrush = nullptr;
    HBRUSH fieldBrush = nullptr;
    HICON appIcon = nullptr;
    HICON appIconLarge = nullptr;
    int bodyLineHeight = 18;
    RECT card{};
    RECT hostField{};
    bool hosting = false;
    std::mutex pairMu;
    std::string pendingPairId;
    std::string pendingPairName;
    std::wstring host;
    RemoteInvite invite;
    std::mutex relayMu;
    RelaySocket* relay = nullptr;
    std::atomic<bool> welcomed{false};
    std::atomic<bool> relayFailed{false};
    int preferredSeat = 0;
    std::string deviceId;
    int joinSeat = 1;
    bool flipY = false;

    std::atomic<bool> stop{false};
    std::atomic<bool> streaming{false};
    std::thread sessionThread;
    std::atomic<SOCKET> videoSock{INVALID_SOCKET};
    std::atomic<SOCKET> audioSock{INVALID_SOCKET};

    std::mutex statusMu;
    std::string status = "Enter a host's IP address or paste a remote co-op invite, then Join. Or Host this PC so a Mac can join you (you are Player 1).";

    std::mutex frameMu;
    std::vector<uint8_t> frame;
    int frameW = 0;
    int frameH = 0;
    BITMAPINFO frameInfo{};

    void setStatus(const std::string& text) {
        {
            std::lock_guard<std::mutex> lock(statusMu);
            status = text;
        }
        logLine(text);
        if (hwnd) PostMessageW(hwnd, WM_APP_STATUS, 0, 0);
    }

    void publishFrame(std::vector<uint8_t> bgra, int w, int h) {
        if (flipY && h > 1) {
            int row = w * 4;
            std::vector<uint8_t> tmp(row);
            for (int y = 0; y < h / 2; y++) {
                uint8_t* a = bgra.data() + (size_t)y * row;
                uint8_t* b = bgra.data() + (size_t)(h - 1 - y) * row;
                memcpy(tmp.data(), a, row);
                memcpy(a, b, row);
                memcpy(b, tmp.data(), row);
            }
        }
        {
            std::lock_guard<std::mutex> lock(frameMu);
            frame.swap(bgra);
            frameW = w;
            frameH = h;
            frameInfo = {};
            frameInfo.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
            frameInfo.bmiHeader.biWidth = w;
            frameInfo.bmiHeader.biHeight = -h;
            frameInfo.bmiHeader.biPlanes = 1;
            frameInfo.bmiHeader.biBitCount = 32;
            frameInfo.bmiHeader.biCompression = BI_RGB;
        }
        if (hwnd) PostMessageW(hwnd, WM_APP_FRAME, 0, 0);
    }

    void start() {
        if (sessionThread.joinable()) return;
        int length = GetWindowTextLengthW(hostEdit);
        std::wstring text(length + 1, L'\0');
        GetWindowTextW(hostEdit, text.data(), length + 1);
        text.resize(length);
        host = text;
        while (!host.empty() && iswspace(host.front())) host.erase(host.begin());
        while (!host.empty() && iswspace(host.back())) host.pop_back();
        if (host.empty()) {
            setStatus("Enter the host IP address, or paste the remote co-op invite line.");
            return;
        }
        bool remote = looksLikeInvite(host);
        if (remote && !parseInvite(host, invite)) {
            setStatus("That invite line looks incomplete. Paste the whole GBEAR1 line your friend sent.");
            return;
        }
        preferredSeat = (int)SendMessageW(seatCombo, CB_GETCURSEL, 0, 0);
        if (preferredSeat < 0) preferredSeat = 0;
        stop.store(false);
        EnableWindow(hostEdit, FALSE);
        EnableWindow(seatCombo, FALSE);
        EnableWindow(hostButton, FALSE);
        SetWindowTextW(joinButton, L"Leave");
        if (remote) {
            host.clear();
            sessionThread = std::thread([this] { runRelaySession(); });
        } else {
            sessionThread = std::thread([this] { runSession(); });
        }
    }

    void startHosting() {
        if (hosting || sessionThread.joinable() || streaming.load()) return;
        GBearHostCallbacks callbacks;
        callbacks.onStatus = [this](const std::string& text) { setStatus(text); };
        callbacks.onPairRequest = [this](const std::string& id, const std::string& name) {
            {
                std::lock_guard<std::mutex> lock(pairMu);
                pendingPairId = id;
                pendingPairName = name;
            }
            if (hwnd) PostMessageW(hwnd, WM_APP_PAIR, 0, 0);
        };
        std::string error;
        if (!gbearHostStart(callbacks, error)) {
            setStatus(error.empty() ? "Could not start hosting." : error);
            return;
        }
        hosting = true;
        EnableWindow(hostEdit, FALSE);
        EnableWindow(seatCombo, FALSE);
        EnableWindow(joinButton, FALSE);
        EnableWindow(pairButton, FALSE);
        SetWindowTextW(hostButton, L"Stop hosting");
        InvalidateRect(hwnd, nullptr, FALSE);
    }

    void stopHosting() {
        if (!hosting) return;
        gbearHostStop();
        hosting = false;
        EnableWindow(hostEdit, TRUE);
        EnableWindow(seatCombo, TRUE);
        EnableWindow(joinButton, TRUE);
        EnableWindow(pairButton, FALSE);
        SetWindowTextW(hostButton, L"Host this PC");
        setStatus("Stopped hosting.");
    }

    void leave() {
        stop.store(true);
        {
            std::lock_guard<std::mutex> lock(relayMu);
            if (relay) relay->abort();
        }
        SOCKET video = videoSock.exchange(INVALID_SOCKET);
        SOCKET audio = audioSock.exchange(INVALID_SOCKET);
        if (video != INVALID_SOCKET) closesocket(video);
        if (audio != INVALID_SOCKET) closesocket(audio);
        if (sessionThread.joinable()) sessionThread.join();
        EnableWindow(hostEdit, TRUE);
        EnableWindow(seatCombo, TRUE);
        EnableWindow(hostButton, TRUE);
        SetWindowTextW(joinButton, L"Join");
        streaming.store(false);
    }

    void runSession() {
        deviceId = loadOrCreateDeviceId();
        std::string name = deviceName();
        std::string hostUtf8 = wideToUtf8(host);
        setStatus("Asking the Mac to pair…");
        std::string pairBody = std::string("{\"deviceId\":\"") + jsonEscape(deviceId) + "\",\"deviceName\":\"" + jsonEscape(name) + "\",\"clientKind\":\"computerGuest\"}";
        HttpResult pair = httpRequest(host, L"POST", L"/gbear/v1/pair/request", pairBody);
        if (!pair.error.empty()) {
            setStatus(pair.error);
            PostMessageW(hwnd, WM_APP_PHASE, 0, 0);
            return;
        }
        if (pair.status >= 400) {
            std::string err = jsonString(pair.body, "error");
            setStatus(err.empty() ? "Pairing was rejected." : err);
            PostMessageW(hwnd, WM_APP_PHASE, 0, 0);
            return;
        }
        bool paired = false;
        for (int i = 0; i < 300 && !stop.load(); i++) {
            std::wstring path = L"/gbear/v1/pair/status?deviceId=" + utf8ToWide(deviceId);
            HttpResult status = httpRequest(host, L"GET", path, "");
            std::string state = jsonString(status.body, "status");
            if (state == "paired") {
                paired = true;
                break;
            }
            if (state == "denied") {
                setStatus("The host denied pairing.");
                PostMessageW(hwnd, WM_APP_PHASE, 0, 0);
                return;
            }
            setStatus("Waiting for Pair on the host…");
            Sleep(1000);
        }
        if (!paired || stop.load()) {
            if (!stop.load()) setStatus("Timed out waiting for the host to approve pairing.");
            PostMessageW(hwnd, WM_APP_PHASE, 0, 0);
            return;
        }
        setStatus("Paired. Starting stream…");
        std::string startBody = std::string("{\"deviceId\":\"") + jsonEscape(deviceId) + "\",\"deviceName\":\"" + jsonEscape(name) + "\",\"clientKind\":\"computerGuest\",\"width\":1920,\"height\":1080,\"fps\":60";
        if (preferredSeat >= 1) startBody += ",\"preferredSeat\":" + std::to_string(preferredSeat);
        startBody += "}";
        HttpResult started = httpRequest(host, L"POST", L"/gbear/v1/stream/start", startBody);
        if (!jsonOk(started.body)) {
            std::string err = jsonString(started.body, "error");
            setStatus(err.empty() ? "Stream start failed." : err);
            PostMessageW(hwnd, WM_APP_PHASE, 0, 0);
            return;
        }
        joinSeat = jsonInt(started.body, "seat", 2);
        if (joinSeat < 1) joinSeat = 1;
        if (joinSeat > 8) joinSeat = 8;
        int videoPort = jsonInt(started.body, "videoPort", kVideoPort);
        int audioPort = jsonInt(started.body, "audioTcpPort", kAudioPort);
        int inputPort = jsonInt(started.body, "inputPort", kInputPort);
        streaming.store(true);
        setStatus("Playing as Player " + std::to_string(joinSeat) + ". I flips the picture. Esc leaves.");
        std::thread videoThread([this, hostUtf8, videoPort] { videoLoop(hostUtf8, (uint16_t)videoPort); });
        std::thread audioThread([this, hostUtf8, audioPort] { audioLoop(hostUtf8, (uint16_t)audioPort); });
        std::thread padThread([this, hostUtf8, inputPort] { padLoop(hostUtf8, (uint16_t)inputPort); });
        videoThread.join();
        audioThread.join();
        padThread.join();
        if (!host.empty() && !deviceId.empty()) {
            std::string stopBody = std::string("{\"deviceId\":\"") + jsonEscape(deviceId) + "\"}";
            httpRequest(host, L"POST", L"/gbear/v1/stream/stop", stopBody);
        }
        streaming.store(false);
        if (stop.load()) setStatus("Disconnected.");
        PostMessageW(hwnd, WM_APP_PHASE, 0, 0);
    }

    static void padPacket(uint8_t packet[33], const PadState& pad, int seat) {
        uint32_t magic = kGamepadMagic;
        uint32_t buttons = pad.buttons;
        memcpy(packet, &magic, 4);
        packet[4] = (uint8_t)seat;
        memcpy(packet + 5, &buttons, 4);
        float axes[6] = {pad.lx, pad.ly, pad.rx, pad.ry, pad.lt, pad.rt};
        memcpy(packet + 9, axes, sizeof(axes));
    }

    // A GBV1 packet: 13-byte header, then Annex B H.264.
    void decodeVideoPacket(H264Decoder& decoder, const uint8_t* data, size_t size) {
        if (size < (size_t)kVideoHeader) return;
        uint32_t magic = 0, length = 0;
        memcpy(&magic, data, 4);
        memcpy(&length, data + 4, 4);
        if (magic != kVideoMagic || length == 0 || kVideoHeader + (size_t)length > size) return;
        bool keyframe = (data[8] & 1) != 0;
        uint16_t w = 0, h = 0;
        memcpy(&w, data + 9, 2);
        memcpy(&h, data + 11, 2);
        if (w == 0 || h == 0 || !decoder.ensure(w, h)) return;
        std::vector<uint8_t> bgra;
        int outW = 0, outH = 0;
        if (decoder.decode(data + kVideoHeader, length, keyframe, bgra, outW, outH)) publishFrame(std::move(bgra), outW, outH);
    }

    // A GBA1 packet: 11-byte header, then 16-bit PCM.
    static void playAudioPacket(AudioPlayer& player, const uint8_t* data, size_t size) {
        if (size < (size_t)kAudioHeader) return;
        uint32_t magic = 0, payloadLen = 0;
        memcpy(&magic, data, 4);
        memcpy(&payloadLen, data + 4, 4);
        if (magic != kAudioMagic || payloadLen == 0 || kAudioHeader + (size_t)payloadLen > size) return;
        uint16_t rate = 0;
        memcpy(&rate, data + 8, 2);
        uint8_t channels = data[10];
        if (rate == 0) rate = 48000;
        if (channels == 0) channels = 2;
        player.play(data + kAudioHeader, (int)payloadLen, rate, channels);
    }

    void sendRelayHello(RelaySocket& socket, const std::string& name) {
        std::string hello = std::string("{\"type\":\"hello\",\"deviceId\":\"") + jsonEscape(deviceId) + "\",\"deviceName\":\"" +
                            jsonEscape(name) + "\",\"preferredSeat\":" + std::to_string(preferredSeat) + "}";
        socket.send(tunnelFrame(kChannelControl, hello.data(), hello.size()));
    }

    HttpResult relayPost(const std::wstring& path, const std::string& body) {
        return httpCall(invite.host, invite.port, invite.secure, L"POST", path, body, L"Authorization: Bearer dev:guest@gbear.local\r\n", 20000);
    }

    void failRelay(const std::string& message) {
        relayFailed.store(true);
        setStatus(message);
        stop.store(true);
    }

    // Remote co-op through the invite's relay: redeem the code, then one WebSocket carries video,
    // audio, and controller packets in GBTL frames.
    void runRelaySession() {
        deviceId = loadOrCreateDeviceId();
        std::string name = deviceName();
        welcomed.store(false);
        relayFailed.store(false);
        setStatus("Reaching your friend's Mac…");
        std::string registerBody = std::string("{\"deviceId\":\"") + jsonEscape(deviceId) + "\",\"deviceName\":\"" + jsonEscape(name) + "\",\"role\":\"guest\"}";
        HttpResult registered = relayPost(L"/v1/auth/register-device", registerBody);
        if (!registered.error.empty() || registered.status < 200 || registered.status >= 300) {
            setStatus(registered.error.empty()
                ? "The invite address answered with HTTP " + std::to_string(registered.status) + ". Ask your friend for a new invite line."
                : "Could not reach your friend's Mac. Check the invite line and that remote co-op is still running.");
            PostMessageW(hwnd, WM_APP_PHASE, 0, 0);
            return;
        }
        std::string redeemBody = std::string("{\"inviteCode\":\"") + jsonEscape(invite.code) + "\",\"deviceId\":\"" + jsonEscape(deviceId) +
                                 "\",\"deviceName\":\"" + jsonEscape(name) + "\"}";
        HttpResult redeemed = relayPost(L"/v1/session/redeem-invite", redeemBody);
        std::string sessionId = jsonString(redeemed.body, "sessionId");
        if (sessionId.empty() || stop.load()) {
            if (stop.load()) {
                setStatus("Disconnected.");
            } else if (!redeemed.error.empty()) {
                setStatus("Your friend's Mac did not answer. Check that remote co-op is still running there.");
            } else if (redeemed.status == 404) {
                setStatus("That invite has expired or ended. Ask your friend to start remote co-op again and send a new line.");
            } else {
                std::string err = jsonString(redeemed.body, "error");
                setStatus(err.empty() ? "That invite was not accepted. Ask your friend for a new invite line." : "The host refused: " + err);
            }
            PostMessageW(hwnd, WM_APP_PHASE, 0, 0);
            return;
        }
        std::wstring path = L"/v1/ws?deviceId=" + urlEncode(deviceId) + L"&sessionId=" + urlEncode(sessionId) + L"&mode=relay";

        // Decoding runs on its own thread so pings and audio never wait behind a big frame.
        std::mutex videoMu;
        std::condition_variable videoReady;
        std::deque<std::vector<uint8_t>> videoQueue;
        bool awaitingKeyframe = true;
        std::thread videoThread([&] {
            H264Decoder decoder;
            while (!stop.load()) {
                std::vector<uint8_t> packet;
                {
                    std::unique_lock<std::mutex> lock(videoMu);
                    videoReady.wait_for(lock, std::chrono::milliseconds(200), [&] { return !videoQueue.empty() || stop.load(); });
                    if (videoQueue.empty()) continue;
                    packet = std::move(videoQueue.front());
                    videoQueue.pop_front();
                }
                decodeVideoPacket(decoder, packet.data(), packet.size());
            }
        });

        DWORD joinStarted = GetTickCount();
        std::thread padThread([&] {
            PadState previous;
            DWORD lastSend = 0;
            bool sent = false;
            while (!stop.load()) {
                if (!welcomed.load()) {
                    if (GetTickCount() - joinStarted > 45000) {
                        failRelay("The host did not answer. Make sure remote co-op is still running on the Mac.");
                        std::lock_guard<std::mutex> lock(relayMu);
                        if (relay) relay->abort();
                        break;
                    }
                    Sleep(50);
                    continue;
                }
                PadState pad = readPad();
                DWORD now = GetTickCount();
                if (!sent || !(pad == previous) || now - lastSend >= 50) {
                    uint8_t packet[33];
                    padPacket(packet, pad, joinSeat);
                    std::lock_guard<std::mutex> lock(relayMu);
                    if (relay) relay->send(tunnelFrame(kChannelInput, packet, sizeof(packet)));
                    previous = pad;
                    lastSend = now;
                    sent = true;
                }
                Sleep(8);
            }
        });

        AudioPlayer player;
        int attempts = 0;
        std::vector<uint8_t> message;
        while (!stop.load()) {
            RelaySocket socket;
            {
                std::lock_guard<std::mutex> lock(relayMu);
                relay = &socket;
            }
            std::string error;
            std::string dropReason;
            if (stop.load()) {
                dropReason = "left";
            } else if (!socket.open(invite, path, error)) {
                dropReason = error;
            } else {
                logLine("relay connected");
                bool text = false;
                while (!stop.load() && socket.receive(message, text)) {
                    if (text) {
                        std::string body(message.begin(), message.end());
                        std::string type = jsonString(body, "type");
                        if (type == "relay_ready") {
                            sendRelayHello(socket, name);
                            if (!welcomed.load()) setStatus("Connected. Waiting for the host to start the picture…");
                        } else if (type == "peer_left") {
                            setStatus("The host's connection blipped. Waiting for it to come back…");
                        }
                        continue;
                    }
                    if (message.size() < (size_t)kTunnelHeader) continue;
                    uint32_t magic = 0, length = 0;
                    memcpy(&magic, message.data(), 4);
                    memcpy(&length, message.data() + 5, 4);
                    if (magic != kTunnelMagic || kTunnelHeader + (size_t)length > message.size()) continue;
                    uint8_t channel = message[4];
                    const uint8_t* payload = message.data() + kTunnelHeader;
                    if (channel == kChannelVideo) {
                        bool keyframe = length > 8 && (payload[8] & 1) != 0;
                        std::lock_guard<std::mutex> lock(videoMu);
                        // After a drop H.264 frames reference the missing one, so skip to the next keyframe.
                        if (awaitingKeyframe && !keyframe) continue;
                        awaitingKeyframe = false;
                        if (videoQueue.size() >= 30) {
                            videoQueue.clear();
                            awaitingKeyframe = !keyframe;
                            if (!keyframe) continue;
                        }
                        videoQueue.emplace_back(payload, payload + length);
                        videoReady.notify_one();
                    } else if (channel == kChannelAudio) {
                        playAudioPacket(player, payload, length);
                    } else if (channel == kChannelControl) {
                        std::string body(payload, payload + length);
                        std::string type = jsonString(body, "type");
                        if (type == "ping") {
                            // Answered right here so the host's round trip measures the network.
                            std::string pong = "{\"type\":\"pong\",\"t\":" + jsonRaw(body, "t") + "}";
                            socket.send(tunnelFrame(kChannelControl, pong.data(), pong.size()));
                        } else if (type == "welcome") {
                            joinSeat = std::clamp(jsonInt(body, "seat", 2), 1, 8);
                            attempts = 0;
                            welcomed.store(true);
                            streaming.store(true);
                            setStatus("Playing as Player " + std::to_string(joinSeat) + " over remote co-op. I flips the picture. Esc leaves.");
                            PostMessageW(hwnd, WM_APP_PHASE, 0, 0);
                        } else if (type == "error") {
                            std::string err = jsonString(body, "error");
                            failRelay(err.empty() ? "The host rejected the join." : err);
                        }
                    }
                }
                dropReason = "connection closed";
                std::lock_guard<std::mutex> lock(videoMu);
                awaitingKeyframe = true;
            }
            {
                std::lock_guard<std::mutex> lock(relayMu);
                relay = nullptr;
            }
            if (stop.load()) break;
            attempts++;
            logLine("relay dropped: " + dropReason);
            if (attempts > 8 || (!welcomed.load() && attempts > 2)) {
                failRelay(welcomed.load()
                    ? "Lost the host (" + dropReason + "). Paste the invite and join again."
                    : "Could not reach the host (" + dropReason + "). Check the invite line and try again.");
                break;
            }
            setStatus("Connection dropped. Reconnecting…");
            for (int i = 0; i < attempts * 4 && !stop.load(); i++) Sleep(100);
        }
        stop.store(true);
        videoReady.notify_all();
        videoThread.join();
        padThread.join();
        player.stop();
        streaming.store(false);
        if (!relayFailed.load()) setStatus("Disconnected.");
        PostMessageW(hwnd, WM_APP_PHASE, 0, 0);
    }

    void videoLoop(const std::string& hostUtf8, uint16_t port) {
        H264Decoder decoder;
        SOCKET sock = INVALID_SOCKET;
        for (int attempt = 0; attempt < 25 && !stop.load(); attempt++) {
            sock = connectTCP(hostUtf8, port);
            if (sock != INVALID_SOCKET) break;
            Sleep(200);
        }
        if (sock == INVALID_SOCKET) {
            setStatus("Could not open the video connection.");
            stop.store(true);
            return;
        }
        videoSock.store(sock);
        logLine("video connected");
        while (!stop.load()) {
            uint8_t header[kVideoHeader];
            if (!recvExact(sock, header, kVideoHeader, stop)) break;
            uint32_t magic = 0, length = 0;
            memcpy(&magic, header, 4);
            memcpy(&length, header + 4, 4);
            if (magic != kVideoMagic || length == 0 || length > 8 * 1024 * 1024) {
                logLine("bad video frame");
                break;
            }
            bool keyframe = (header[8] & 1) != 0;
            uint16_t w = 0, h = 0;
            memcpy(&w, header + 9, 2);
            memcpy(&h, header + 11, 2);
            std::vector<uint8_t> payload(length);
            if (!recvExact(sock, payload.data(), (int)length, stop)) break;
            if (w == 0 || h == 0) continue;
            if (!decoder.ensure(w, h)) continue;
            std::vector<uint8_t> bgra;
            int outW = 0, outH = 0;
            if (decoder.decode(payload.data(), length, keyframe, bgra, outW, outH)) publishFrame(std::move(bgra), outW, outH);
        }
        SOCKET current = videoSock.exchange(INVALID_SOCKET);
        if (current != INVALID_SOCKET) closesocket(current);
        if (!stop.load()) {
            setStatus("Video connection closed.");
            stop.store(true);
        }
    }

    void audioLoop(const std::string& hostUtf8, uint16_t port) {
        AudioPlayer player;
        SOCKET sock = INVALID_SOCKET;
        for (int attempt = 0; attempt < 25 && !stop.load(); attempt++) {
            sock = connectTCP(hostUtf8, port);
            if (sock != INVALID_SOCKET) break;
            Sleep(200);
        }
        if (sock == INVALID_SOCKET) {
            logLine("audio connect failed");
            return;
        }
        audioSock.store(sock);
        logLine("audio connected");
        while (!stop.load()) {
            uint32_t outer = 0;
            if (!recvExact(sock, &outer, 4, stop)) break;
            if (outer < (uint32_t)kAudioHeader || outer > 512000) break;
            std::vector<uint8_t> packet(outer);
            if (!recvExact(sock, packet.data(), (int)outer, stop)) break;
            uint32_t magic = 0, payloadLen = 0;
            memcpy(&magic, packet.data(), 4);
            memcpy(&payloadLen, packet.data() + 4, 4);
            if (magic != kAudioMagic) continue;
            uint16_t rate = 0;
            memcpy(&rate, packet.data() + 8, 2);
            uint8_t channels = packet[10];
            if (payloadLen == 0 || kAudioHeader + payloadLen > packet.size()) continue;
            if (rate == 0) rate = 48000;
            if (channels == 0) channels = 2;
            player.play(packet.data() + kAudioHeader, (int)payloadLen, rate, channels);
        }
        player.stop();
        SOCKET current = audioSock.exchange(INVALID_SOCKET);
        if (current != INVALID_SOCKET) closesocket(current);
    }

    void padLoop(const std::string& hostUtf8, uint16_t port) {
        addrinfo hints{};
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_DGRAM;
        addrinfo* info = nullptr;
        std::string portText = std::to_string(port);
        if (getaddrinfo(hostUtf8.c_str(), portText.c_str(), &hints, &info) != 0) return;
        SOCKET sock = socket(info->ai_family, info->ai_socktype, info->ai_protocol);
        if (sock == INVALID_SOCKET) {
            freeaddrinfo(info);
            return;
        }
        PadState previous;
        DWORD lastSend = 0;
        bool sent = false;
        while (!stop.load()) {
            PadState pad = readPad();
            DWORD now = GetTickCount();
            if (!sent || !(pad == previous) || now - lastSend >= 50) {
                uint8_t packet[33];
                uint32_t magic = kGamepadMagic;
                uint32_t buttons = pad.buttons;
                memcpy(packet, &magic, 4);
                packet[4] = (uint8_t)joinSeat;
                memcpy(packet + 5, &buttons, 4);
                float axes[6] = {pad.lx, pad.ly, pad.rx, pad.ry, pad.lt, pad.rt};
                memcpy(packet + 9, axes, sizeof(axes));
                sendto(sock, (char*)packet, 33, 0, info->ai_addr, (int)info->ai_addrlen);
                previous = pad;
                lastSend = now;
                sent = true;
            }
            Sleep(8);
        }
        uint8_t neutral[33] = {};
        uint32_t magic = kGamepadMagic;
        memcpy(neutral, &magic, 4);
        neutral[4] = (uint8_t)joinSeat;
        sendto(sock, (char*)neutral, 33, 0, info->ai_addr, (int)info->ai_addrlen);
        closesocket(sock);
        freeaddrinfo(info);
    }

    PadState readPad() {
        XINPUT_STATE xinput{};
        for (DWORD index = 0; index < 4; index++) {
            if (XInputGetState(index, &xinput) == ERROR_SUCCESS) return fromXInput(xinput.Gamepad);
        }
        return fromKeyboard();
    }

    static float stick(SHORT value) {
        const float dead = 7849.f;
        float f = (float)value;
        float mag = fabsf(f);
        if (mag < dead) return 0;
        float scaled = (mag - dead) / (32767.f - dead);
        if (scaled > 1.f) scaled = 1.f;
        return copysignf(scaled, f);
    }

    static PadState fromXInput(const XINPUT_GAMEPAD& pad) {
        PadState out;
        auto set = [&](uint32_t bit, WORD mask) {
            if (pad.wButtons & mask) out.buttons |= bit;
        };
        set(kA, XINPUT_GAMEPAD_A);
        set(kB, XINPUT_GAMEPAD_B);
        set(kX, XINPUT_GAMEPAD_X);
        set(kY, XINPUT_GAMEPAD_Y);
        set(kL1, XINPUT_GAMEPAD_LEFT_SHOULDER);
        set(kR1, XINPUT_GAMEPAD_RIGHT_SHOULDER);
        set(kL3, XINPUT_GAMEPAD_LEFT_THUMB);
        set(kR3, XINPUT_GAMEPAD_RIGHT_THUMB);
        set(kStart, XINPUT_GAMEPAD_START);
        set(kSelect, XINPUT_GAMEPAD_BACK);
        set(kUp, XINPUT_GAMEPAD_DPAD_UP);
        set(kDown, XINPUT_GAMEPAD_DPAD_DOWN);
        set(kLeft, XINPUT_GAMEPAD_DPAD_LEFT);
        set(kRight, XINPUT_GAMEPAD_DPAD_RIGHT);
        out.lx = stick(pad.sThumbLX);
        out.ly = stick(pad.sThumbLY);
        out.rx = stick(pad.sThumbRX);
        out.ry = stick(pad.sThumbRY);
        out.lt = pad.bLeftTrigger / 255.f;
        out.rt = pad.bRightTrigger / 255.f;
        return out;
    }

    PadState fromKeyboard() {
        PadState out;
        if (!hwnd || GetForegroundWindow() != hwnd) return out;
        auto down = [](int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; };
        if (down('W')) out.ly += 1;
        if (down('S')) out.ly -= 1;
        if (down('A')) out.lx -= 1;
        if (down('D')) out.lx += 1;
        if (down(VK_UP)) out.buttons |= kUp;
        if (down(VK_DOWN)) out.buttons |= kDown;
        if (down(VK_LEFT)) out.buttons |= kLeft;
        if (down(VK_RIGHT)) out.buttons |= kRight;
        if (down(VK_SPACE)) out.buttons |= kA;
        if (down('C')) out.buttons |= kB;
        if (down('F')) out.buttons |= kX;
        if (down('R')) out.buttons |= kY;
        if (down('Q')) out.buttons |= kL1;
        if (down('E')) out.buttons |= kR1;
        if (down(VK_SHIFT)) out.lt = 1;
        if (down(VK_CONTROL)) out.rt = 1;
        if (down(VK_RETURN)) out.buttons |= kStart;
        if (down(VK_BACK)) out.buttons |= kSelect;
        return out;
    }

    int S(double value) const { return (int)std::lround(value * scale); }
    int headerHeight() const { return S(172); }
    int appBarHeight() const { return S(60); }

    void createUi(HINSTANCE inst) {
        HDC screen = GetDC(nullptr);
        scale = GetDeviceCaps(screen, LOGPIXELSX) / 96.0;
        auto font = [&](int px, int weight) {
            return CreateFontW(-S(px), 0, 0, 0, weight, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                               CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
        };
        titleFont = font(20, FW_SEMIBOLD);
        bodyFont = font(14, FW_NORMAL);
        buttonFont = font(14, FW_SEMIBOLD);
        smallFont = font(12, FW_NORMAL);
        headlineFont = font(18, FW_SEMIBOLD);
        HGDIOBJ old = SelectObject(screen, bodyFont);
        TEXTMETRICW metrics{};
        GetTextMetricsW(screen, &metrics);
        bodyLineHeight = metrics.tmHeight;
        SelectObject(screen, old);
        ReleaseDC(nullptr, screen);

        backgroundBrush = CreateSolidBrush(ui::kBackground);
        surfaceBrush = CreateSolidBrush(ui::kSurface);
        cardBrush = CreateSolidBrush(ui::kCard);
        fieldBrush = CreateSolidBrush(ui::kField);
        appIcon = (HICON)LoadImageW(inst, MAKEINTRESOURCEW(1), IMAGE_ICON, S(32), S(32), 0);
        appIconLarge = (HICON)LoadImageW(inst, MAKEINTRESOURCEW(1), IMAGE_ICON, S(96), S(96), 0);
    }

    void layout() {
        if (!hwnd || !hostEdit) return;
        RECT client;
        GetClientRect(hwnd, &client);
        int cardX = S(20);
        int cardY = appBarHeight() + S(16);
        int cardH = S(64);
        card = RECT{cardX, cardY, std::max(cardX + S(200), (int)client.right - S(20)), cardY + cardH};
        int fieldH = S(36);
        int y = cardY + (cardH - fieldH) / 2;
        int x = cardX + S(14);
        int hostW = S(260);
        hostField = RECT{x, y, x + hostW, y + fieldH};
        int editH = bodyLineHeight + S(2);
        MoveWindow(hostEdit, x + S(12), y + (fieldH - editH) / 2, hostW - S(24), editH, TRUE);
        x += hostW + S(10);
        RECT comboRect;
        GetWindowRect(seatCombo, &comboRect);
        int comboH = comboRect.bottom - comboRect.top;
        MoveWindow(seatCombo, x, y + (fieldH - comboH) / 2, S(200), S(320), TRUE);
        x += S(200) + S(16);
        MoveWindow(joinButton, x, y, S(96), fieldH, TRUE);
        x += S(96) + S(10);
        MoveWindow(hostButton, x, y, S(140), fieldH, TRUE);
        x += S(140) + S(10);
        MoveWindow(pairButton, x, y, S(88), fieldH, TRUE);
    }

    COLORREF statusDotColor() const {
        if (streaming.load()) return ui::kSuccess;
        if (hosting) return ui::kPrimary;
        if (sessionThread.joinable()) return ui::kWaiting;
        return ui::kTextTertiary;
    }

    void paintHeader(HDC dc, int width) {
        int height = headerHeight();
        int barH = appBarHeight();
        RECT all{0, 0, width, height};
        FillRect(dc, &all, backgroundBrush);
        RECT bar{0, 0, width, barH};
        FillRect(dc, &bar, surfaceBrush);
        RECT divider{0, barH - 1, width, barH};
        HBRUSH outline = CreateSolidBrush(ui::kOutline);
        FillRect(dc, &divider, outline);
        DeleteObject(outline);

        int statusY = card.bottom + (height - card.bottom) / 2;
        {
            Gdiplus::Graphics g(dc);
            g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
            float cardW = (float)(card.right - card.left);
            float cardH = (float)(card.bottom - card.top);
            ui::fillRounded(g, (float)card.left, (float)card.top, cardW, cardH, (float)S(12), ui::kCard);
            ui::strokeRounded(g, (float)card.left, (float)card.top, cardW, cardH, (float)S(12), ui::kOutline, 1.0f);
            float fieldW = (float)(hostField.right - hostField.left);
            float fieldH = (float)(hostField.bottom - hostField.top);
            ui::fillRounded(g, (float)hostField.left, (float)hostField.top, fieldW, fieldH, (float)S(10), ui::kField);
            ui::strokeRounded(g, (float)hostField.left, (float)hostField.top, fieldW, fieldH, (float)S(10), ui::kFieldOutline, 1.0f);
            Gdiplus::SolidBrush dot(ui::color(statusDotColor()));
            g.FillEllipse(&dot, (float)S(26), (float)(statusY - S(4)), (float)S(8), (float)S(8));
        }

        int x = S(20);
        if (appIcon) {
            DrawIconEx(dc, x, (barH - S(32)) / 2, appIcon, S(32), S(32), 0, nullptr, DI_NORMAL);
            x += S(32) + S(12);
        }
        std::wstring title = L"GBear";
        ui::drawText(dc, titleFont, ui::kText, title, RECT{x, 0, width, barH}, DT_SINGLELINE | DT_VCENTER | DT_LEFT);
        x += ui::textWidth(dc, titleFont, title) + S(10);
        ui::drawText(dc, bodyFont, ui::kTextSecondary, L"Couch co-op", RECT{x, S(2), width, barH}, DT_SINGLELINE | DT_VCENTER | DT_LEFT);
        ui::drawText(dc, smallFont, ui::kTextTertiary, L"Esc leaves the stream  \u00B7  I flips the picture",
                     RECT{0, 0, width - S(20), barH}, DT_SINGLELINE | DT_VCENTER | DT_RIGHT);

        std::string text;
        {
            std::lock_guard<std::mutex> lock(statusMu);
            text = status;
        }
        ui::drawText(dc, bodyFont, ui::kTextSecondary, utf8ToWide(text),
                     RECT{S(42), statusY - S(12), width - S(20), statusY + S(12)},
                     DT_SINGLELINE | DT_VCENTER | DT_LEFT | DT_END_ELLIPSIS);
    }

    void paintPlaceholder(HDC dc, RECT area) {
        FillRect(dc, &area, backgroundBrush);
        int cx = (area.left + area.right) / 2;
        int cy = (area.top + area.bottom) / 2;
        int iconSize = S(96);
        int top = cy - S(90);
        if (appIconLarge) {
            DrawIconEx(dc, cx - iconSize / 2, top, appIconLarge, iconSize, iconSize, 0, nullptr, DI_NORMAL);
        }
        top += iconSize + S(20);
        ui::drawText(dc, headlineFont, ui::kText, L"No picture yet",
                     RECT{area.left, top, area.right, top + S(28)}, DT_SINGLELINE | DT_CENTER | DT_VCENTER);
        top += S(32);
        std::wstring hint = hosting
            ? L"You're hosting. The Mac that joins sees this PC's screen and plays as another player."
            : L"Enter the host's IP address, or paste your friend's GBEAR1 invite line, and choose Join.";
        ui::drawText(dc, bodyFont, ui::kTextSecondary, hint,
                     RECT{area.left + S(20), top, area.right - S(20), top + S(24)}, DT_SINGLELINE | DT_CENTER | DT_VCENTER | DT_END_ELLIPSIS);
    }

    void paint(HDC dc) {
        RECT client;
        GetClientRect(hwnd, &client);
        int top = headerHeight();

        HDC mem = CreateCompatibleDC(dc);
        HBITMAP bitmap = CreateCompatibleBitmap(dc, std::max(1, (int)client.right), top);
        HGDIOBJ oldBitmap = SelectObject(mem, bitmap);
        paintHeader(mem, client.right);
        BitBlt(dc, 0, 0, client.right, top, mem, 0, 0, SRCCOPY);
        SelectObject(mem, oldBitmap);
        DeleteObject(bitmap);
        DeleteDC(mem);

        RECT video{0, top, client.right, client.bottom};
        std::vector<uint8_t> copy;
        int w = 0, h = 0;
        BITMAPINFO info{};
        {
            std::lock_guard<std::mutex> lock(frameMu);
            copy = frame;
            w = frameW;
            h = frameH;
            info = frameInfo;
        }
        if (copy.empty() || w <= 0 || h <= 0) {
            paintPlaceholder(dc, video);
            return;
        }
        // Keep the host screen's shape; fill the rest of the area with black.
        int areaW = client.right;
        int areaH = client.bottom - top;
        int drawW = areaW;
        int drawH = areaW > 0 ? (int)((long long)areaW * h / w) : 0;
        if (drawH > areaH) {
            drawH = areaH;
            drawW = (int)((long long)areaH * w / h);
        }
        int drawX = (areaW - drawW) / 2;
        int drawY = top + (areaH - drawH) / 2;
        HBRUSH black = (HBRUSH)GetStockObject(BLACK_BRUSH);
        RECT bar{0, top, client.right, drawY};
        FillRect(dc, &bar, black);
        bar = RECT{0, drawY + drawH, client.right, client.bottom};
        FillRect(dc, &bar, black);
        bar = RECT{0, drawY, drawX, drawY + drawH};
        FillRect(dc, &bar, black);
        bar = RECT{drawX + drawW, drawY, client.right, drawY + drawH};
        FillRect(dc, &bar, black);
        SetStretchBltMode(dc, HALFTONE);
        StretchDIBits(
            dc,
            drawX,
            drawY,
            drawW,
            drawH,
            0,
            0,
            w,
            h,
            copy.data(),
            &info,
            DIB_RGB_COLORS,
            SRCCOPY
        );
    }

    void drawButton(const DRAWITEMSTRUCT* item) {
        RECT rc = item->rcItem;
        int w = rc.right - rc.left;
        int h = rc.bottom - rc.top;
        if (w <= 0 || h <= 0) return;
        HDC mem = CreateCompatibleDC(item->hDC);
        HBITMAP bitmap = CreateCompatibleBitmap(item->hDC, w, h);
        HGDIOBJ oldBitmap = SelectObject(mem, bitmap);
        RECT local{0, 0, w, h};
        FillRect(mem, &local, cardBrush);

        wchar_t label[64] = L"";
        GetWindowTextW(item->hwndItem, label, 64);
        bool disabled = (item->itemState & ODS_DISABLED) != 0;
        bool pressed = (item->itemState & ODS_SELECTED) != 0;
        bool filled = true;
        COLORREF accent = ui::kPrimary;
        if (item->CtlID == IDC_JOIN) {
            if (wcscmp(label, L"Leave") == 0) accent = ui::kDanger;
        } else if (item->CtlID == IDC_HOST_BTN) {
            filled = false;
            accent = hosting ? ui::kDanger : ui::kText;
        } else if (disabled) {
            filled = false;
            accent = ui::kText;
        }
        BYTE alpha = disabled ? 97 : 255;
        {
            Gdiplus::Graphics g(mem);
            g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
            float radius = h / 2.0f;
            if (filled) {
                COLORREF fill = pressed ? ui::blend(accent, RGB(0, 0, 0), 0.18f) : accent;
                ui::fillRounded(g, 0, 0, (float)w, (float)h, radius, fill, alpha);
            } else {
                if (pressed) ui::fillRounded(g, 0, 0, (float)w, (float)h, radius, accent, 36);
                ui::strokeRounded(g, 0, 0, (float)w, (float)h, radius, accent, (float)std::max(1.0, 1.5 * scale), alpha);
            }
        }
        COLORREF textColor = filled ? (accent == ui::kDanger ? RGB(255, 255, 255) : ui::kBackground) : accent;
        if (disabled) textColor = ui::blend(ui::kCard, filled ? textColor : accent, 0.38f);
        ui::drawText(mem, buttonFont, textColor, label, local, DT_SINGLELINE | DT_CENTER | DT_VCENTER);
        BitBlt(item->hDC, rc.left, rc.top, w, h, mem, 0, 0, SRCCOPY);
        SelectObject(mem, oldBitmap);
        DeleteObject(bitmap);
        DeleteDC(mem);
    }

    void drawSeatItem(const DRAWITEMSTRUCT* item) {
        int index = (int)item->itemID;
        if (index < 0) index = (int)SendMessageW(item->hwndItem, CB_GETCURSEL, 0, 0);
        wchar_t text[64] = L"";
        if (index >= 0) SendMessageW(item->hwndItem, CB_GETLBTEXT, index, (LPARAM)text);
        bool field = (item->itemState & ODS_COMBOBOXEDIT) != 0;
        bool selected = (item->itemState & ODS_SELECTED) != 0;
        bool disabled = (item->itemState & ODS_DISABLED) != 0;
        COLORREF background = (!field && selected) ? ui::blend(ui::kField, ui::kPrimary, 0.28f) : ui::kField;
        HBRUSH brush = CreateSolidBrush(background);
        FillRect(item->hDC, &item->rcItem, brush);
        DeleteObject(brush);
        RECT r = item->rcItem;
        r.left += S(10);
        if (field) {
            std::wstring prefix = L"Join as  ";
            ui::drawText(item->hDC, bodyFont, ui::kTextTertiary, prefix, r, DT_SINGLELINE | DT_VCENTER | DT_LEFT);
            r.left += ui::textWidth(item->hDC, bodyFont, prefix);
        }
        ui::drawText(item->hDC, bodyFont, disabled ? ui::kTextTertiary : ui::kText, text, r,
                     DT_SINGLELINE | DT_VCENTER | DT_LEFT | DT_END_ELLIPSIS);
    }

    LRESULT handle(HWND window, UINT msg, WPARAM wParam, LPARAM lParam) {
        switch (msg) {
        case WM_COMMAND:
            if (LOWORD(wParam) == IDC_JOIN) {
                if (hosting) return 0;
                if (sessionThread.joinable() || streaming.load()) leave();
                else start();
            } else if (LOWORD(wParam) == IDC_HOST_BTN) {
                if (hosting) stopHosting();
                else startHosting();
            } else if (LOWORD(wParam) == IDC_PAIR) {
                std::string id;
                std::string name;
                {
                    std::lock_guard<std::mutex> lock(pairMu);
                    id = pendingPairId;
                    name = pendingPairName;
                }
                gbearHostApprove(id);
                EnableWindow(pairButton, FALSE);
                setStatus("Paired " + (name.empty() ? "the Mac" : name) + ". Their GBear guest will open the stream.");
            }
            return 0;
        case WM_APP_PAIR: {
            std::string name;
            {
                std::lock_guard<std::mutex> lock(pairMu);
                name = pendingPairName;
            }
            SetWindowTextW(pairButton, L"Pair");
            EnableWindow(pairButton, TRUE);
            setStatus((name.empty() ? "A Mac" : name) + " wants to join. Click Pair.");
            return 0;
        }
        case WM_APP_STATUS:
            RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_ALLCHILDREN);
            return 0;
        case WM_APP_FRAME: {
            RECT client;
            GetClientRect(window, &client);
            RECT video{0, headerHeight(), client.right, client.bottom};
            InvalidateRect(window, &video, FALSE);
            return 0;
        }
        case WM_APP_PHASE:
            RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_ALLCHILDREN);
            if (!streaming.load()) {
                EnableWindow(hostEdit, TRUE);
                EnableWindow(seatCombo, TRUE);
                EnableWindow(hostButton, TRUE);
                SetWindowTextW(joinButton, L"Join");
                if (sessionThread.joinable()) {
                    stop.store(true);
                    sessionThread.join();
                }
            }
            return 0;
        case WM_KEYDOWN:
            if (wParam == VK_ESCAPE && (sessionThread.joinable() || streaming.load())) leave();
            if (wParam == 'I') {
                flipY = !flipY;
                setStatus(flipY ? "Picture flipped." : "Picture flip off.");
            }
            return 0;
        case WM_PAINT: {
            PAINTSTRUCT ps;
            HDC dc = BeginPaint(window, &ps);
            paint(dc);
            EndPaint(window, &ps);
            return 0;
        }
        case WM_ERASEBKGND:
            return 1;
        case WM_SIZE:
            layout();
            InvalidateRect(window, nullptr, FALSE);
            return 0;
        case WM_GETMINMAXINFO: {
            auto* info = reinterpret_cast<MINMAXINFO*>(lParam);
            info->ptMinTrackSize.x = S(920);
            info->ptMinTrackSize.y = S(540);
            return 0;
        }
        case WM_MEASUREITEM: {
            auto* item = reinterpret_cast<MEASUREITEMSTRUCT*>(lParam);
            if (item->CtlType == ODT_COMBOBOX) {
                item->itemHeight = item->itemID == (UINT)-1 ? S(28) : S(30);
                return TRUE;
            }
            break;
        }
        case WM_DRAWITEM: {
            auto* item = reinterpret_cast<const DRAWITEMSTRUCT*>(lParam);
            if (item->CtlType == ODT_BUTTON) {
                drawButton(item);
                return TRUE;
            }
            if (item->CtlType == ODT_COMBOBOX) {
                drawSeatItem(item);
                return TRUE;
            }
            break;
        }
        case WM_CTLCOLOREDIT:
        case WM_CTLCOLORSTATIC:
        case WM_CTLCOLORLISTBOX: {
            HDC dc = (HDC)wParam;
            bool dim = msg == WM_CTLCOLORSTATIC;
            SetTextColor(dc, dim ? ui::kTextSecondary : ui::kText);
            SetBkColor(dc, ui::kField);
            return (LRESULT)fieldBrush;
        }
        case WM_DESTROY:
            stop.store(true);
            if (hosting) stopHosting();
            leave();
            PostQuitMessage(0);
            return 0;
        default:
            break;
        }
        return DefWindowProcW(window, msg, wParam, lParam);
    }
};

GuestApp gApp;

// A single-line edit keeps only the first line of pasted text, and chat apps wrap the long invite
// address, so line breaks become spaces (the invite parser joins the address back up). Enter joins.
LRESULT CALLBACK hostEditProc(HWND edit, UINT msg, WPARAM wParam, LPARAM lParam, UINT_PTR, DWORD_PTR) {
    if (msg == WM_PASTE) {
        if (!OpenClipboard(edit)) return 0;
        std::wstring text;
        if (HANDLE data = GetClipboardData(CF_UNICODETEXT)) {
            if (auto* chars = static_cast<const wchar_t*>(GlobalLock(data))) {
                text = chars;
                GlobalUnlock(data);
            }
        }
        CloseClipboard();
        for (auto& c : text) {
            if (c == L'\r' || c == L'\n' || c == L'\t') c = L' ';
        }
        SendMessageW(edit, EM_REPLACESEL, TRUE, (LPARAM)text.c_str());
        return 0;
    }
    if (msg == WM_CHAR && wParam == VK_RETURN) {
        PostMessageW(GetParent(edit), WM_COMMAND, MAKEWPARAM(IDC_JOIN, BN_CLICKED), (LPARAM)edit);
        return 0;
    }
    return DefSubclassProc(edit, msg, wParam, lParam);
}

LRESULT CALLBACK wndProc(HWND window, UINT msg, WPARAM wParam, LPARAM lParam) {
    return gApp.handle(window, msg, wParam, lParam);
}

}  // namespace

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int show) {
    gApp.instance = inst;
    wchar_t exePath[MAX_PATH];
    GetModuleFileNameW(nullptr, exePath, MAX_PATH);
    gLogPath = exePath;
    auto slash = gLogPath.find_last_of(L"\\/");
    if (slash != std::wstring::npos) gLogPath.resize(slash + 1);
    gLogPath += L"gbear-guest.log";
    logLine("GBear Windows guest started");

    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    SetProcessDPIAware();

    INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_STANDARD_CLASSES};
    InitCommonControlsEx(&controls);
    Gdiplus::GdiplusStartupInput gdiplusInput;
    ULONG_PTR gdiplusToken = 0;
    Gdiplus::GdiplusStartup(&gdiplusToken, &gdiplusInput, nullptr);
    gApp.createUi(inst);

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = inst;
    wc.lpszClassName = L"GBearGuest";
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = gApp.backgroundBrush;
    wc.hIcon = (HICON)LoadImageW(inst, MAKEINTRESOURCEW(1), IMAGE_ICON, GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), 0);
    wc.hIconSm = (HICON)LoadImageW(inst, MAKEINTRESOURCEW(1), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0);
    RegisterClassExW(&wc);

    RECT work{};
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    int windowW = std::min(gApp.S(1280), (int)((work.right - work.left) * 0.9));
    int windowH = std::min(gApp.S(800), (int)((work.bottom - work.top) * 0.9));
    gApp.hwnd = CreateWindowExW(
        0,
        L"GBearGuest",
        L"GBear",
        WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        windowW,
        windowH,
        nullptr,
        nullptr,
        inst,
        nullptr
    );
    // Dark title bar (Windows 10 20H1+) tinted like the app bar (Windows 11).
    BOOL darkTitle = TRUE;
    DwmSetWindowAttribute(gApp.hwnd, 20, &darkTitle, sizeof(darkTitle));
    COLORREF caption = ui::kSurface;
    DwmSetWindowAttribute(gApp.hwnd, 35, &caption, sizeof(caption));
    DwmSetWindowAttribute(gApp.hwnd, 34, &caption, sizeof(caption));

    gApp.hostEdit = CreateWindowExW(0, L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL, 0, 0, 10, 10, gApp.hwnd, (HMENU)IDC_HOST, inst, nullptr);
    SendMessageW(gApp.hostEdit, WM_SETFONT, (WPARAM)gApp.bodyFont, TRUE);
    SendMessageW(gApp.hostEdit, EM_SETCUEBANNER, TRUE, (LPARAM)L"Host IP or invite line");
    SetWindowSubclass(gApp.hostEdit, hostEditProc, 0, 0);
    gApp.seatCombo = CreateWindowExW(0, L"COMBOBOX", L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP | CBS_DROPDOWNLIST | CBS_OWNERDRAWFIXED | CBS_HASSTRINGS, 0, 0, 10, 300, gApp.hwnd, (HMENU)IDC_SEAT, inst, nullptr);
    SendMessageW(gApp.seatCombo, WM_SETFONT, (WPARAM)gApp.bodyFont, TRUE);
    SetWindowTheme(gApp.seatCombo, L"DarkMode_CFD", nullptr);
    SendMessageW(gApp.seatCombo, CB_ADDSTRING, 0, (LPARAM)L"Next open seat");
    for (int i = 1; i <= 8; i++) {
        wchar_t label[32];
        swprintf(label, 32, L"Player %d", i);
        SendMessageW(gApp.seatCombo, CB_ADDSTRING, 0, (LPARAM)label);
    }
    SendMessageW(gApp.seatCombo, CB_SETCURSEL, 0, 0);
    DWORD buttonStyle = WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW;
    gApp.joinButton = CreateWindowExW(0, L"BUTTON", L"Join", buttonStyle, 0, 0, 10, 10, gApp.hwnd, (HMENU)IDC_JOIN, inst, nullptr);
    gApp.hostButton = CreateWindowExW(0, L"BUTTON", L"Host this PC", buttonStyle, 0, 0, 10, 10, gApp.hwnd, (HMENU)IDC_HOST_BTN, inst, nullptr);
    gApp.pairButton = CreateWindowExW(0, L"BUTTON", L"Pair", buttonStyle | WS_DISABLED, 0, 0, 10, 10, gApp.hwnd, (HMENU)IDC_PAIR, inst, nullptr);
    gApp.layout();
    ShowWindow(gApp.hwnd, show);

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    Gdiplus::GdiplusShutdown(gdiplusToken);
    MFShutdown();
    CoUninitialize();
    WSACleanup();
    return 0;
}
