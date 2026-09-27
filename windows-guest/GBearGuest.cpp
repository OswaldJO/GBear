// Windows couch-co-op app. Join a GBear host, or host so a Mac can join.
// Speaks gbear-stream/1: HTTP pair + stream/start, TCP GBV1 video, TCP GBA1 audio, UDP GBG1 pads.

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

#include "GBearWinHost.h"

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

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

constexpr UINT WM_APP_STATUS = WM_APP + 1;
constexpr UINT WM_APP_FRAME = WM_APP + 2;
constexpr UINT WM_APP_PHASE = WM_APP + 3;
constexpr UINT WM_APP_PAIR = WM_APP + 4;

constexpr int IDC_HOST = 101;
constexpr int IDC_SEAT = 102;
constexpr int IDC_JOIN = 103;
constexpr int IDC_STATUS = 104;
constexpr int IDC_HOST_BTN = 105;
constexpr int IDC_PAIR = 106;

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
    std::string pat = std::string("\"") + key + "\":\"";
    auto pos = body.find(pat);
    if (pos == std::string::npos) return "";
    pos += pat.size();
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

struct HttpResult {
    int status = 0;
    std::string body;
    std::string error;
};

HttpResult httpRequest(const std::wstring& host, const wchar_t* method, const std::wstring& path, const std::string& body) {
    HttpResult result;
    HINTERNET session = WinHttpOpen(L"GBearGuest/1", WINHTTP_ACCESS_TYPE_NO_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) {
        result.error = "WinHTTP open failed";
        return result;
    }
    HINTERNET connect = WinHttpConnect(session, host.c_str(), kControlPort, 0);
    if (!connect) {
        result.error = "Could not connect to host on port 28765";
        WinHttpCloseHandle(session);
        return result;
    }
    HINTERNET request = WinHttpOpenRequest(connect, method, path.c_str(), nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, 0);
    if (!request) {
        result.error = "Could not open HTTP request";
        WinHttpCloseHandle(connect);
        WinHttpCloseHandle(session);
        return result;
    }
    WinHttpSetTimeouts(request, 4000, 4000, 8000, 8000);
    const wchar_t* headers = body.empty() ? WINHTTP_NO_ADDITIONAL_HEADERS : L"Content-Type: application/json\r\n";
    BOOL ok = WinHttpSendRequest(
        request,
        headers,
        headers ? (DWORD)-1 : 0,
        body.empty() ? WINHTTP_NO_REQUEST_DATA : (LPVOID)body.data(),
        (DWORD)body.size(),
        (DWORD)body.size(),
        0
    );
    if (!ok || !WinHttpReceiveResponse(request, nullptr)) {
        result.error = "Host did not answer on port 28765. Is GBear open to the Streaming tab, and is the Mac firewall allowing it?";
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
    HWND statusLabel = nullptr;
    bool hosting = false;
    std::mutex pairMu;
    std::string pendingPairId;
    std::string pendingPairName;
    std::wstring host;
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
    std::string status = "Join a host, or Host this PC so a Mac can join you. You are Player 1 when you host.";

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
        wchar_t ip[256];
        GetWindowTextW(hostEdit, ip, 256);
        host = ip;
        while (!host.empty() && iswspace(host.front())) host.erase(host.begin());
        while (!host.empty() && iswspace(host.back())) host.pop_back();
        if (host.empty()) {
            setStatus("Enter the host IP address.");
            return;
        }
        preferredSeat = (int)SendMessageW(seatCombo, CB_GETCURSEL, 0, 0);
        if (preferredSeat < 0) preferredSeat = 0;
        stop.store(false);
        EnableWindow(hostEdit, FALSE);
        EnableWindow(seatCombo, FALSE);
        EnableWindow(hostButton, FALSE);
        SetWindowTextW(joinButton, L"Leave");
        sessionThread = std::thread([this] { runSession(); });
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

    void paint(HDC dc) {
        RECT client;
        GetClientRect(hwnd, &client);
        int top = 80;
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
            FillRect(dc, &video, (HBRUSH)(COLOR_WINDOW + 1));
            return;
        }
        SetStretchBltMode(dc, HALFTONE);
        StretchDIBits(
            dc,
            0,
            top,
            client.right,
            client.bottom - top,
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
        case WM_APP_STATUS: {
            std::string text;
            {
                std::lock_guard<std::mutex> lock(statusMu);
                text = status;
            }
            SetWindowTextW(statusLabel, utf8ToWide(text).c_str());
            return 0;
        }
        case WM_APP_FRAME:
            InvalidateRect(window, nullptr, FALSE);
            return 0;
        case WM_APP_PHASE:
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
        case WM_DESTROY:
            stop.store(true);
            if (hosting) stopHosting();
            leave();
            PostQuitMessage(0);
            return 0;
        default:
            return DefWindowProcW(window, msg, wParam, lParam);
        }
    }
};

GuestApp gApp;

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

    WNDCLASSW wc{};
    wc.lpfnWndProc = wndProc;
    wc.hInstance = inst;
    wc.lpszClassName = L"GBearGuest";
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    RegisterClassW(&wc);
    gApp.hwnd = CreateWindowExW(
        0,
        L"GBearGuest",
        L"GBear",
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        1280,
        760,
        nullptr,
        nullptr,
        inst,
        nullptr
    );
    gApp.hostEdit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL, 8, 8, 280, 24, gApp.hwnd, (HMENU)IDC_HOST, inst, nullptr);
    gApp.seatCombo = CreateWindowExW(0, L"COMBOBOX", L"", WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST, 296, 8, 150, 240, gApp.hwnd, (HMENU)IDC_SEAT, inst, nullptr);
    SendMessageW(gApp.seatCombo, CB_ADDSTRING, 0, (LPARAM)L"Next open seat");
    for (int i = 1; i <= 8; i++) {
        wchar_t label[32];
        swprintf(label, 32, L"Player %d", i);
        SendMessageW(gApp.seatCombo, CB_ADDSTRING, 0, (LPARAM)label);
    }
    SendMessageW(gApp.seatCombo, CB_SETCURSEL, 0, 0);
    gApp.joinButton = CreateWindowExW(0, L"BUTTON", L"Join", WS_CHILD | WS_VISIBLE, 454, 8, 80, 24, gApp.hwnd, (HMENU)IDC_JOIN, inst, nullptr);
    gApp.hostButton = CreateWindowExW(0, L"BUTTON", L"Host this PC", WS_CHILD | WS_VISIBLE, 542, 8, 120, 24, gApp.hwnd, (HMENU)IDC_HOST_BTN, inst, nullptr);
    gApp.pairButton = CreateWindowExW(0, L"BUTTON", L"Pair", WS_CHILD | WS_VISIBLE | WS_DISABLED, 670, 8, 80, 24, gApp.hwnd, (HMENU)IDC_PAIR, inst, nullptr);
    gApp.statusLabel = CreateWindowExW(0, L"STATIC", utf8ToWide(gApp.status).c_str(), WS_CHILD | WS_VISIBLE, 8, 40, 1240, 34, gApp.hwnd, (HMENU)IDC_STATUS, inst, nullptr);
    ShowWindow(gApp.hwnd, show);

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    MFShutdown();
    CoUninitialize();
    WSACleanup();
    return 0;
}
