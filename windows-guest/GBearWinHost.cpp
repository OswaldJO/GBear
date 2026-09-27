// Host mode for the Windows GBear app. Speaks the same ports as the Mac host so
// a Mac can join with Streaming → Join another computer.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX

#include "GBearWinHost.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mferror.h>
#include <codecapi.h>
#include <icodecapi.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <mmreg.h>

#include "ViGEm/Client.h"

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr uint16_t kControlPort = 28765;
constexpr uint16_t kVideoPort = 28766;
constexpr uint16_t kAudioPort = 28769;
constexpr uint16_t kInputPort = 28768;
constexpr uint32_t kVideoMagic = 0x31564247;
constexpr uint32_t kAudioMagic = 0x31414247;
constexpr uint32_t kGamepadMagic = 0x31474247;
constexpr int kMaxW = 1280;
constexpr int kMaxH = 720;

struct VideoClient {
    SOCKET sock = INVALID_SOCKET;
    bool needKeyframe = true;
};

struct AudioClient {
    SOCKET sock = INVALID_SOCKET;
};

struct RemotePad {
    PVIGEM_TARGET target = nullptr;
};

class Host {
public:
    GBearHostCallbacks cb;
    std::atomic<bool> running{false};
    std::thread httpThread;
    std::thread videoAcceptThread;
    std::thread audioAcceptThread;
    std::thread inputThread;
    std::thread captureThread;
    std::thread audioThread;

    SOCKET httpListen = INVALID_SOCKET;
    SOCKET videoListen = INVALID_SOCKET;
    SOCKET audioListen = INVALID_SOCKET;
    SOCKET inputSock = INVALID_SOCKET;

    std::mutex stateMu;
    std::map<std::string, std::string> pending;
    std::map<std::string, std::string> paired;
    std::map<std::string, int> seats;

    std::mutex clientMu;
    std::vector<VideoClient> videoClients;
    std::vector<AudioClient> audioClients;
    std::atomic<bool> forceKeyframe{true};

    std::mutex vigemMu;
    PVIGEM_CLIENT vigem = nullptr;
    bool vigemReady = false;
    std::map<int, RemotePad> pads;

    void status(const std::string& text) {
        if (cb.onStatus) cb.onStatus(text);
    }

    std::string ipv4List() {
        ULONG size = 15 * 1024;
        std::vector<unsigned char> buffer(size);
        ULONG flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER;
        ULONG rc = GetAdaptersAddresses(AF_INET, flags, nullptr, reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data()), &size);
        if (rc == ERROR_BUFFER_OVERFLOW) {
            buffer.resize(size);
            rc = GetAdaptersAddresses(AF_INET, flags, nullptr, reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data()), &size);
        }
        if (rc != NO_ERROR) return "this PC";
        std::string tailscale;
        std::string lan;
        for (auto* adapter = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data()); adapter; adapter = adapter->Next) {
            if (adapter->OperStatus != IfOperStatusUp) continue;
            for (auto* unicast = adapter->FirstUnicastAddress; unicast; unicast = unicast->Next) {
                if (!unicast->Address.lpSockaddr || unicast->Address.lpSockaddr->sa_family != AF_INET) continue;
                auto* in = reinterpret_cast<sockaddr_in*>(unicast->Address.lpSockaddr);
                char text[64];
                inet_ntop(AF_INET, &in->sin_addr, text, sizeof(text));
                std::string ip = text;
                if (ip == "127.0.0.1") continue;
                unsigned first = (unsigned)(unsigned char)ip[0];
                unsigned second = 0;
                auto dot = ip.find('.');
                if (dot != std::string::npos) second = (unsigned)atoi(ip.c_str() + dot + 1);
                if (first == 100 && second >= 64 && second <= 127) {
                    if (tailscale.empty()) tailscale = ip;
                } else if (lan.empty()) {
                    lan = ip;
                }
            }
        }
        if (!lan.empty() && !tailscale.empty()) return lan + " (Tailscale " + tailscale + ")";
        if (!tailscale.empty()) return tailscale;
        if (!lan.empty()) return lan;
        return "this PC";
    }
};

Host* gHost = nullptr;

std::string jsonField(const std::string& body, const char* key) {
    std::string pat = std::string("\"") + key + "\":\"";
    auto pos = body.find(pat);
    if (pos == std::string::npos) return "";
    pos += pat.size();
    std::string out;
    while (pos < body.size() && body[pos] != '"') out.push_back(body[pos++]);
    return out;
}

int jsonInt(const std::string& body, const char* key, int fallback) {
    std::string pat = std::string("\"") + key + "\":";
    auto pos = body.find(pat);
    if (pos == std::string::npos) return fallback;
    pos += pat.size();
    while (pos < body.size() && body[pos] == ' ') pos++;
    return atoi(body.c_str() + pos);
}

std::string httpResponse(int code, const std::string& json) {
    const char* reason = "OK";
    if (code == 400) reason = "Bad Request";
    else if (code == 403) reason = "Forbidden";
    else if (code == 404) reason = "Not Found";
    else if (code == 409) reason = "Conflict";
    std::string out = "HTTP/1.1 " + std::to_string(code) + " " + reason + "\r\n";
    out += "Content-Type: application/json\r\nContent-Length: " + std::to_string(json.size()) + "\r\nConnection: close\r\n\r\n";
    out += json;
    return out;
}

std::string urlDecode(std::string value) {
    std::string out;
    for (size_t i = 0; i < value.size(); i++) {
        if (value[i] == '%' && i + 2 < value.size()) {
            int hex = 0;
            if (sscanf(value.c_str() + i + 1, "%2x", &hex) == 1) {
                out.push_back((char)hex);
                i += 2;
                continue;
            }
        }
        if (value[i] == '+') out.push_back(' ');
        else out.push_back(value[i]);
    }
    return out;
}

bool sendAll(SOCKET sock, const void* data, int count) {
    const char* p = static_cast<const char*>(data);
    int sent = 0;
    while (sent < count) {
        int n = send(sock, p + sent, count - sent, 0);
        if (n <= 0) return false;
        sent += n;
    }
    return true;
}

SOCKET listenTCP(uint16_t port) {
    SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock == INVALID_SOCKET) return INVALID_SOCKET;
    BOOL reuse = TRUE;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, (char*)&reuse, sizeof(reuse));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(port);
    if (bind(sock, (sockaddr*)&addr, sizeof(addr)) != 0 || listen(sock, 8) != 0) {
        closesocket(sock);
        return INVALID_SOCKET;
    }
    return sock;
}

bool recvSome(SOCKET sock, std::string& data) {
    char buf[8192];
    int n = recv(sock, buf, sizeof(buf), 0);
    if (n <= 0) return false;
    data.append(buf, buf + n);
    return true;
}

std::string pairStatus(Host& host, const std::string& id) {
    std::lock_guard<std::mutex> lock(host.stateMu);
    if (host.pending.count(id)) return "pending";
    if (host.paired.count(id)) return "paired";
    return "unknown";
}

int assignSeat(Host& host, const std::string& id, int preferred) {
    std::lock_guard<std::mutex> lock(host.stateMu);
    auto existing = host.seats.find(id);
    if (existing != host.seats.end()) return existing->second;
    bool used[9] = {};
    used[1] = true;
    for (const auto& seat : host.seats) {
        if (seat.second >= 1 && seat.second <= 8) used[seat.second] = true;
    }
    int chosen = 0;
    if (preferred >= 2 && preferred <= 8 && !used[preferred]) chosen = preferred;
    if (chosen == 0) {
        for (int seat = 2; seat <= 8; seat++) {
            if (!used[seat]) {
                chosen = seat;
                break;
            }
        }
    }
    if (chosen == 0) return -1;
    host.seats[id] = chosen;
    return chosen;
}

void ensurePad(Host& host, int seat) {
    std::lock_guard<std::mutex> lock(host.vigemMu);
    if (!host.vigemReady || host.pads.count(seat)) return;
    PVIGEM_TARGET target = vigem_target_x360_alloc();
    if (!target) return;
    if (vigem_target_add(host.vigem, target) != VIGEM_ERROR_NONE) {
        vigem_target_free(target);
        host.status("Could not add a virtual Xbox pad. Install ViGEmBus, then host again.");
        return;
    }
    host.pads[seat].target = target;
    host.status("Virtual Xbox pad ready for Player " + std::to_string(seat) + ".");
}

void clearSeat(Host& host, const std::string& id) {
    int seat = 0;
    {
        std::lock_guard<std::mutex> lock(host.stateMu);
        auto it = host.seats.find(id);
        if (it == host.seats.end()) return;
        seat = it->second;
        host.seats.erase(it);
    }
    std::lock_guard<std::mutex> lock(host.vigemMu);
    auto pad = host.pads.find(seat);
    if (pad == host.pads.end()) return;
    if (host.vigem && pad->second.target) {
        XUSB_REPORT report{};
        vigem_target_x360_update(host.vigem, pad->second.target, report);
        vigem_target_remove(host.vigem, pad->second.target);
        vigem_target_free(pad->second.target);
    }
    host.pads.erase(pad);
}

std::string handleHTTP(Host& host, const std::string& method, const std::string& path, const std::string& query, const std::string& body) {
    if (method == "POST" && path == "/gbear/v1/pair/request") {
        std::string id = jsonField(body, "deviceId");
        std::string name = jsonField(body, "deviceName");
        if (id.empty()) return httpResponse(400, "{\"ok\":false,\"error\":\"deviceId required\"}");
        if (name.empty()) name = "Mac";
        {
            std::lock_guard<std::mutex> lock(host.stateMu);
            host.pending[id] = name;
        }
        if (host.cb.onPairRequest) host.cb.onPairRequest(id, name);
        host.status(name + " wants to join. Click Pair.");
        return httpResponse(200, "{\"ok\":true,\"status\":\"pending\"}");
    }
    if (method == "GET" && path == "/gbear/v1/pair/status") {
        auto key = query.find("deviceId=");
        std::string id;
        if (key != std::string::npos) {
            id = query.substr(key + 9);
            auto amp = id.find('&');
            if (amp != std::string::npos) id.resize(amp);
            id = urlDecode(id);
        }
        if (id.empty()) return httpResponse(400, "{\"error\":\"deviceId required\"}");
        return httpResponse(200, std::string("{\"status\":\"") + pairStatus(host, id) + "\"}");
    }
    if (method == "POST" && path == "/gbear/v1/stream/start") {
        std::string id = jsonField(body, "deviceId");
        {
            std::lock_guard<std::mutex> lock(host.stateMu);
            if (!host.paired.count(id)) return httpResponse(403, "{\"ok\":false,\"error\":\"not paired\"}");
        }
        int preferred = jsonInt(body, "preferredSeat", 0);
        int seat = assignSeat(host, id, preferred);
        if (seat < 1) return httpResponse(409, "{\"ok\":false,\"error\":\"Session full\"}");
        ensurePad(host, seat);
        host.forceKeyframe.store(true);
        host.status("Player " + std::to_string(seat) + " joined. You are Player 1 on this PC.");
        return httpResponse(
            200,
            std::string("{\"ok\":true,\"seat\":") + std::to_string(seat) +
                ",\"videoPort\":28766,\"audioPort\":28767,\"audioTcpPort\":28769,\"inputPort\":28768,\"attached\":true}"
        );
    }
    if (method == "POST" && path == "/gbear/v1/stream/stop") {
        std::string id = jsonField(body, "deviceId");
        if (!id.empty()) clearSeat(host, id);
        host.status("A player left.");
        return httpResponse(200, "{\"ok\":true}");
    }
    if (method == "GET" && path == "/gbear/v1/status") {
        return httpResponse(200, "{\"protocol\":\"gbear-stream/1\",\"videoStreaming\":true,\"maxViewers\":8}");
    }
    return httpResponse(404, "{\"ok\":false,\"error\":\"not found\"}");
}

void httpLoop(Host* host) {
    while (host->running.load()) {
        sockaddr_in from{};
        int fromLen = sizeof(from);
        SOCKET client = accept(host->httpListen, (sockaddr*)&from, &fromLen);
        if (client == INVALID_SOCKET) break;
        DWORD timeout = 3000;
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, (char*)&timeout, sizeof(timeout));
        std::string data;
        while (data.find("\r\n\r\n") == std::string::npos) {
            if (!recvSome(client, data)) break;
            if (data.size() > 1024 * 1024) break;
        }
        auto headerEnd = data.find("\r\n\r\n");
        if (headerEnd != std::string::npos) {
            std::string headers = data.substr(0, headerEnd);
            std::string body = data.substr(headerEnd + 4);
            int contentLength = 0;
            auto lenPos = headers.find("Content-Length:");
            if (lenPos == std::string::npos) lenPos = headers.find("content-length:");
            if (lenPos != std::string::npos) contentLength = atoi(headers.c_str() + lenPos + 15);
            while ((int)body.size() < contentLength) {
                if (!recvSome(client, data)) break;
                body = data.substr(headerEnd + 4);
            }
            if ((int)body.size() > contentLength) body.resize(contentLength);
            std::string method;
            std::string path;
            auto lineEnd = headers.find("\r\n");
            std::string requestLine = headers.substr(0, lineEnd);
            auto sp1 = requestLine.find(' ');
            auto sp2 = requestLine.find(' ', sp1 == std::string::npos ? 0 : sp1 + 1);
            if (sp1 != std::string::npos) {
                method = requestLine.substr(0, sp1);
                path = requestLine.substr(sp1 + 1, sp2 == std::string::npos ? std::string::npos : sp2 - sp1 - 1);
            }
            std::string query;
            auto q = path.find('?');
            if (q != std::string::npos) {
                query = path.substr(q + 1);
                path.resize(q);
            }
            std::string response = handleHTTP(*host, method, path, query, body);
            sendAll(client, response.data(), (int)response.size());
        }
        closesocket(client);
    }
}

void videoAcceptLoop(Host* host) {
    while (host->running.load()) {
        SOCKET client = accept(host->videoListen, nullptr, nullptr);
        if (client == INVALID_SOCKET) break;
        int one = 1;
        setsockopt(client, IPPROTO_TCP, TCP_NODELAY, (char*)&one, sizeof(one));
        {
            std::lock_guard<std::mutex> lock(host->clientMu);
            host->videoClients.push_back(VideoClient{client, true});
        }
        host->forceKeyframe.store(true);
        host->status("A screen viewer connected.");
    }
}

void audioAcceptLoop(Host* host) {
    while (host->running.load()) {
        SOCKET client = accept(host->audioListen, nullptr, nullptr);
        if (client == INVALID_SOCKET) break;
        std::lock_guard<std::mutex> lock(host->clientMu);
        host->audioClients.push_back(AudioClient{client});
    }
}

SHORT stickToShort(float value) {
    if (value > 1.f) value = 1.f;
    if (value < -1.f) value = -1.f;
    return (SHORT)(value * 32767.f);
}

void applyGamepad(Host* host, const uint8_t* packet, int count) {
    if (count < 33) return;
    uint32_t magic = 0;
    memcpy(&magic, packet, 4);
    if (magic != kGamepadMagic) return;
    uint8_t seat = packet[4];
    uint32_t buttons = 0;
    memcpy(&buttons, packet + 5, 4);
    float axes[6];
    memcpy(axes, packet + 9, sizeof(axes));
    XUSB_REPORT report{};
    auto set = [&](uint32_t bit, USHORT xusb) {
        if (buttons & bit) report.wButtons |= xusb;
    };
    set(1u << 0, XUSB_GAMEPAD_A);
    set(1u << 1, XUSB_GAMEPAD_B);
    set(1u << 2, XUSB_GAMEPAD_X);
    set(1u << 3, XUSB_GAMEPAD_Y);
    set(1u << 4, XUSB_GAMEPAD_LEFT_SHOULDER);
    set(1u << 5, XUSB_GAMEPAD_RIGHT_SHOULDER);
    set(1u << 6, XUSB_GAMEPAD_LEFT_THUMB);
    set(1u << 7, XUSB_GAMEPAD_RIGHT_THUMB);
    set(1u << 8, XUSB_GAMEPAD_START);
    set(1u << 9, XUSB_GAMEPAD_BACK);
    set(1u << 10, XUSB_GAMEPAD_DPAD_UP);
    set(1u << 11, XUSB_GAMEPAD_DPAD_DOWN);
    set(1u << 12, XUSB_GAMEPAD_DPAD_LEFT);
    set(1u << 13, XUSB_GAMEPAD_DPAD_RIGHT);
    report.sThumbLX = stickToShort(axes[0]);
    report.sThumbLY = stickToShort(axes[1]);
    report.sThumbRX = stickToShort(axes[2]);
    report.sThumbRY = stickToShort(axes[3]);
    float lt = axes[4] < 0 ? 0 : (axes[4] > 1 ? 1 : axes[4]);
    float rt = axes[5] < 0 ? 0 : (axes[5] > 1 ? 1 : axes[5]);
    report.bLeftTrigger = (BYTE)(lt * 255.f);
    report.bRightTrigger = (BYTE)(rt * 255.f);
    std::lock_guard<std::mutex> lock(host->vigemMu);
    auto pad = host->pads.find(seat);
    if (pad == host->pads.end() || !host->vigem || !pad->second.target) return;
    vigem_target_x360_update(host->vigem, pad->second.target, report);
}

void inputLoop(Host* host) {
    while (host->running.load()) {
        uint8_t packet[64];
        int n = recvfrom(host->inputSock, (char*)packet, sizeof(packet), 0, nullptr, nullptr);
        if (n <= 0) {
            if (!host->running.load()) break;
            continue;
        }
        applyGamepad(host, packet, n);
    }
}

uint8_t clipByte(int value) {
    if (value < 0) return 0;
    if (value > 255) return 255;
    return (uint8_t)value;
}

void scaleBGRA(const uint8_t* src, int sw, int sh, int stride, std::vector<uint8_t>& dst, int dw, int dh) {
    dst.resize((size_t)dw * dh * 4);
    for (int y = 0; y < dh; y++) {
        int sy = y * sh / dh;
        const uint8_t* row = src + sy * stride;
        uint8_t* out = dst.data() + (size_t)y * dw * 4;
        for (int x = 0; x < dw; x++) {
            int sx = x * sw / dw;
            memcpy(out + x * 4, row + sx * 4, 4);
        }
    }
}

void bgraToNV12(const uint8_t* bgra, int width, int height, std::vector<uint8_t>& nv12) {
    int ySize = width * height;
    nv12.resize((size_t)ySize + ySize / 2);
    uint8_t* yPlane = nv12.data();
    uint8_t* uvPlane = yPlane + ySize;
    for (int y = 0; y < height; y++) {
        const uint8_t* row = bgra + (size_t)y * width * 4;
        for (int x = 0; x < width; x++) {
            int b = row[x * 4], g = row[x * 4 + 1], r = row[x * 4 + 2];
            yPlane[y * width + x] = clipByte(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
        }
    }
    for (int y = 0; y < height; y += 2) {
        for (int x = 0; x < width; x += 2) {
            int r = 0, g = 0, b = 0;
            for (int dy = 0; dy < 2; dy++) {
                const uint8_t* row = bgra + (size_t)(y + dy) * width * 4;
                for (int dx = 0; dx < 2; dx++) {
                    b += row[(x + dx) * 4];
                    g += row[(x + dx) * 4 + 1];
                    r += row[(x + dx) * 4 + 2];
                }
            }
            r /= 4;
            g /= 4;
            b /= 4;
            int u = clipByte(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
            int v = clipByte(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
            int index = (y / 2) * width + x;
            uvPlane[index] = (uint8_t)u;
            uvPlane[index + 1] = (uint8_t)v;
        }
    }
}

void appendAnnexB(std::vector<uint8_t>& out, const uint8_t* data, uint32_t size) {
    if (size >= 4 && data[0] == 0 && data[1] == 0 && ((data[2] == 1) || (data[2] == 0 && data[3] == 1))) {
        out.insert(out.end(), data, data + size);
        return;
    }
    uint32_t offset = 0;
    while (offset + 4 <= size) {
        uint32_t nalLen = 0;
        memcpy(&nalLen, data + offset, 4);
        nalLen = ntohl(nalLen);
        offset += 4;
        if (nalLen == 0 || offset + nalLen > size) break;
        uint8_t start[4] = {0, 0, 0, 1};
        out.insert(out.end(), start, start + 4);
        out.insert(out.end(), data + offset, data + offset + nalLen);
        offset += nalLen;
    }
}

class Encoder {
public:
    IMFTransform* mft = nullptr;
    ICodecAPI* codec = nullptr;
    int width = 0;
    int height = 0;
    LONGLONG pts = 0;
    std::vector<uint8_t> parameterSets;

    void reset() {
        if (codec) {
            codec->Release();
            codec = nullptr;
        }
        if (mft) {
            mft->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
            mft->Release();
            mft = nullptr;
        }
        width = 0;
        height = 0;
        parameterSets.clear();
    }

    bool open(int w, int h) {
        if (mft && width == w && height == h) return true;
        reset();
        MFT_REGISTER_TYPE_INFO outInfo{MFMediaType_Video, MFVideoFormat_H264};
        IMFActivate** activates = nullptr;
        UINT32 count = 0;
        HRESULT hr = MFTEnumEx(
            MFT_CATEGORY_VIDEO_ENCODER,
            MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_SORTANDFILTER,
            nullptr,
            &outInfo,
            &activates,
            &count
        );
        if (FAILED(hr) || count == 0) return false;
        for (UINT32 i = 0; i < count && !mft; i++) {
            IMFTransform* candidate = nullptr;
            if (FAILED(activates[i]->ActivateObject(IID_PPV_ARGS(&candidate))) || !candidate) continue;
            if (configure(candidate, w, h)) mft = candidate;
            else candidate->Release();
        }
        for (UINT32 i = 0; i < count; i++) activates[i]->Release();
        CoTaskMemFree(activates);
        if (!mft) return false;
        width = w;
        height = h;
        mft->QueryInterface(IID_PPV_ARGS(&codec));
        setBitrate();
        mft->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
        mft->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
        mft->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
        return true;
    }

    bool encode(const uint8_t* nv12, bool keyframe, std::vector<uint8_t>& annexB) {
        if (!mft) return false;
        if (keyframe && codec) {
            VARIANT value;
            VariantInit(&value);
            value.vt = VT_UI4;
            value.ulVal = 1;
            codec->SetValue(&CODECAPI_AVEncVideoForceKeyFrame, &value);
            VariantClear(&value);
        }
        DWORD size = (DWORD)(width * height * 3 / 2);
        IMFMediaBuffer* buffer = nullptr;
        if (FAILED(MFCreateMemoryBuffer(size, &buffer))) return false;
        BYTE* dest = nullptr;
        buffer->Lock(&dest, nullptr, nullptr);
        memcpy(dest, nv12, size);
        buffer->Unlock();
        buffer->SetCurrentLength(size);
        IMFSample* sample = nullptr;
        MFCreateSample(&sample);
        sample->AddBuffer(buffer);
        buffer->Release();
        sample->SetSampleTime(pts);
        sample->SetSampleDuration(166667);
        if (keyframe) sample->SetUINT32(MFSampleExtension_CleanPoint, TRUE);
        pts += 166667;
        HRESULT hr = mft->ProcessInput(0, sample, 0);
        sample->Release();
        if (hr == MF_E_NOTACCEPTING) return false;
        if (FAILED(hr)) return false;
        annexB.clear();
        bool produced = false;
        for (int n = 0; n < 8; n++) {
            MFT_OUTPUT_STREAM_INFO info{};
            mft->GetOutputStreamInfo(0, &info);
            MFT_OUTPUT_DATA_BUFFER out{};
            IMFSample* outSample = nullptr;
            IMFMediaBuffer* outBuffer = nullptr;
            bool weOwn = (info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) == 0;
            if (weOwn) {
                DWORD bytes = info.cbSize ? info.cbSize : size;
                MFCreateSample(&outSample);
                MFCreateMemoryBuffer(bytes, &outBuffer);
                outSample->AddBuffer(outBuffer);
                out.pSample = outSample;
            }
            DWORD status = 0;
            hr = mft->ProcessOutput(0, 1, &out, &status);
            if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) {
                if (outSample) outSample->Release();
                if (outBuffer) outBuffer->Release();
                break;
            }
            if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
                if (outSample) outSample->Release();
                if (outBuffer) outBuffer->Release();
                IMFMediaType* type = nullptr;
                if (SUCCEEDED(mft->GetOutputAvailableType(0, 0, &type))) {
                    mft->SetOutputType(0, type, 0);
                    cacheParameterSets(type);
                    type->Release();
                }
                continue;
            }
            if (FAILED(hr) || !out.pSample) {
                if (outSample) outSample->Release();
                if (outBuffer) outBuffer->Release();
                break;
            }
            IMFMediaBuffer* locked = nullptr;
            out.pSample->ConvertToContiguousBuffer(&locked);
            BYTE* data = nullptr;
            DWORD current = 0;
            if (locked && SUCCEEDED(locked->Lock(&data, nullptr, &current)) && current > 0) {
                std::vector<uint8_t> piece;
                appendAnnexB(piece, data, current);
                annexB.insert(annexB.end(), piece.begin(), piece.end());
                locked->Unlock();
                produced = !annexB.empty();
            }
            if (locked) locked->Release();
            if (out.pEvents) out.pEvents->Release();
            if (outSample) outSample->Release();
            else if (out.pSample) out.pSample->Release();
            if (outBuffer) outBuffer->Release();
        }
        if (produced && keyframe && !parameterSets.empty()) {
            std::vector<uint8_t> withSets = parameterSets;
            withSets.insert(withSets.end(), annexB.begin(), annexB.end());
            annexB.swap(withSets);
        }
        return produced;
    }

private:
    bool configure(IMFTransform* candidate, int w, int h) {
        IMFMediaType* outType = nullptr;
        MFCreateMediaType(&outType);
        outType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        outType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
        outType->SetUINT32(MF_MT_AVG_BITRATE, 8000000);
        MFSetAttributeSize(outType, MF_MT_FRAME_SIZE, (UINT32)w, (UINT32)h);
        MFSetAttributeRatio(outType, MF_MT_FRAME_RATE, 60, 1);
        MFSetAttributeRatio(outType, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
        outType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        outType->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Base);
        HRESULT hr = candidate->SetOutputType(0, outType, 0);
        if (FAILED(hr)) {
            outType->DeleteItem(MF_MT_MPEG2_PROFILE);
            hr = candidate->SetOutputType(0, outType, 0);
        }
        outType->Release();
        if (FAILED(hr)) return false;
        IMFMediaType* inType = nullptr;
        MFCreateMediaType(&inType);
        inType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        inType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
        MFSetAttributeSize(inType, MF_MT_FRAME_SIZE, (UINT32)w, (UINT32)h);
        MFSetAttributeRatio(inType, MF_MT_FRAME_RATE, 60, 1);
        MFSetAttributeRatio(inType, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
        inType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        hr = candidate->SetInputType(0, inType, 0);
        inType->Release();
        return SUCCEEDED(hr);
    }

    void setBitrate() {
        if (!codec) return;
        VARIANT value;
        VariantInit(&value);
        value.vt = VT_UI4;
        value.ulVal = eAVEncCommonRateControlMode_CBR;
        codec->SetValue(&CODECAPI_AVEncCommonRateControlMode, &value);
        value.ulVal = 8000000;
        codec->SetValue(&CODECAPI_AVEncCommonMeanBitRate, &value);
        VariantClear(&value);
        VariantInit(&value);
        value.vt = VT_BOOL;
        value.boolVal = VARIANT_TRUE;
        codec->SetValue(&CODECAPI_AVLowLatencyMode, &value);
        VariantClear(&value);
    }

    void cacheParameterSets(IMFMediaType* type) {
        UINT32 blob = 0;
        if (FAILED(type->GetBlobSize(MF_MT_MPEG_SEQUENCE_HEADER, &blob)) || blob < 8) return;
        std::vector<uint8_t> data(blob);
        if (FAILED(type->GetBlob(MF_MT_MPEG_SEQUENCE_HEADER, data.data(), blob, &blob))) return;
        if (data[0] == 0 && data[1] == 0) {
            parameterSets = data;
            return;
        }
        if (data[0] != 1 || blob < 7) return;
        parameterSets.clear();
        int nalLengthSize = (data[4] & 3) + 1;
        int count = data[5] & 0x1F;
        uint32_t offset = 6;
        auto take = [&](int nals) {
            for (int i = 0; i < nals; i++) {
                if (offset + 2 > blob) return;
                uint16_t nalLen = (uint16_t)((data[offset] << 8) | data[offset + 1]);
                offset += 2;
                if (offset + nalLen > blob) return;
                if (nalLengthSize > 0) {
                    uint8_t start[4] = {0, 0, 0, 1};
                    parameterSets.insert(parameterSets.end(), start, start + 4);
                    parameterSets.insert(parameterSets.end(), data.begin() + offset, data.begin() + offset + nalLen);
                }
                offset += nalLen;
            }
        };
        take(count);
        if (offset >= blob) return;
        int ppsCount = data[offset++];
        take(ppsCount);
    }
};

void broadcastVideo(Host* host, const std::vector<uint8_t>& annexB, bool keyframe, uint16_t width, uint16_t height) {
    std::vector<uint8_t> packet;
    packet.resize(13 + annexB.size());
    uint32_t magic = kVideoMagic;
    uint32_t length = (uint32_t)annexB.size();
    memcpy(packet.data(), &magic, 4);
    memcpy(packet.data() + 4, &length, 4);
    packet[8] = keyframe ? 1 : 0;
    memcpy(packet.data() + 9, &width, 2);
    memcpy(packet.data() + 11, &height, 2);
    memcpy(packet.data() + 13, annexB.data(), annexB.size());
    std::lock_guard<std::mutex> lock(host->clientMu);
    for (auto it = host->videoClients.begin(); it != host->videoClients.end();) {
        if (it->needKeyframe && !keyframe) {
            ++it;
            continue;
        }
        if (!sendAll(it->sock, packet.data(), (int)packet.size())) {
            closesocket(it->sock);
            it = host->videoClients.erase(it);
            continue;
        }
        it->needKeyframe = false;
        ++it;
    }
}

void captureLoop(Host* host) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    ID3D11Device* device = nullptr;
    ID3D11DeviceContext* context = nullptr;
    D3D_FEATURE_LEVEL level;
    if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION, &device, &level, &context))) {
        host->status("Could not start graphics capture on this PC.");
        CoUninitialize();
        return;
    }
    IDXGIDevice* dxgiDevice = nullptr;
    device->QueryInterface(IID_PPV_ARGS(&dxgiDevice));
    IDXGIAdapter* adapter = nullptr;
    dxgiDevice->GetParent(IID_PPV_ARGS(&adapter));
    IDXGIOutput* output = nullptr;
    if (FAILED(adapter->EnumOutputs(0, &output)) || !output) {
        host->status("No monitor found to capture.");
        adapter->Release();
        dxgiDevice->Release();
        context->Release();
        device->Release();
        CoUninitialize();
        return;
    }
    IDXGIOutput1* output1 = nullptr;
    output->QueryInterface(IID_PPV_ARGS(&output1));
    IDXGIOutputDuplication* dup = nullptr;
    if (!output1 || FAILED(output1->DuplicateOutput(device, &dup))) {
        host->status("Screen capture was denied. Allow this app to capture the screen.");
        if (output1) output1->Release();
        output->Release();
        adapter->Release();
        dxgiDevice->Release();
        context->Release();
        device->Release();
        CoUninitialize();
        return;
    }
    DXGI_OUTDUPL_DESC dupDesc{};
    dup->GetDesc(&dupDesc);
    ID3D11Texture2D* staging = nullptr;
    Encoder encoder;
    int frameIndex = 0;
    bool loggedFrame = false;
    while (host->running.load()) {
        DXGI_OUTDUPL_FRAME_INFO info{};
        IDXGIResource* resource = nullptr;
        HRESULT hr = dup->AcquireNextFrame(33, &info, &resource);
        if (hr == DXGI_ERROR_WAIT_TIMEOUT) continue;
        if (hr == DXGI_ERROR_ACCESS_LOST) {
            dup->Release();
            dup = nullptr;
            if (FAILED(output1->DuplicateOutput(device, &dup))) break;
            continue;
        }
        if (FAILED(hr) || !resource) continue;
        ID3D11Texture2D* tex = nullptr;
        resource->QueryInterface(IID_PPV_ARGS(&tex));
        resource->Release();
        D3D11_TEXTURE2D_DESC desc{};
        tex->GetDesc(&desc);
        if (!staging) {
            D3D11_TEXTURE2D_DESC stage = desc;
            stage.Usage = D3D11_USAGE_STAGING;
            stage.BindFlags = 0;
            stage.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
            stage.MiscFlags = 0;
            device->CreateTexture2D(&stage, nullptr, &staging);
        }
        context->CopyResource(staging, tex);
        tex->Release();
        dup->ReleaseFrame();
        D3D11_MAPPED_SUBRESOURCE mapped{};
        if (FAILED(context->Map(staging, 0, D3D11_MAP_READ, 0, &mapped))) continue;
        int sw = (int)desc.Width;
        int sh = (int)desc.Height;
        int dw = sw;
        int dh = sh;
        if (dw > kMaxW || dh > kMaxH) {
            double scale = std::min((double)kMaxW / sw, (double)kMaxH / sh);
            dw = std::max(2, ((int)(sw * scale)) & ~1);
            dh = std::max(2, ((int)(sh * scale)) & ~1);
        } else {
            dw &= ~1;
            dh &= ~1;
        }
        std::vector<uint8_t> bgra;
        const uint8_t* pixels = static_cast<const uint8_t*>(mapped.pData);
        if (dw == sw && dh == sh && (int)mapped.RowPitch == sw * 4) bgra.assign(pixels, pixels + (size_t)sw * sh * 4);
        else scaleBGRA(pixels, sw, sh, (int)mapped.RowPitch, bgra, dw, dh);
        context->Unmap(staging, 0);
        std::vector<uint8_t> nv12;
        bgraToNV12(bgra.data(), dw, dh, nv12);
        bool key = host->forceKeyframe.exchange(false) || frameIndex % 60 == 0;
        if (!encoder.open(dw, dh)) {
            host->status("This PC has no H.264 encoder Media Foundation can use.");
            break;
        }
        std::vector<uint8_t> annexB;
        if (encoder.encode(nv12.data(), key, annexB)) {
            broadcastVideo(host, annexB, key, (uint16_t)dw, (uint16_t)dh);
            if (!loggedFrame) {
                loggedFrame = true;
                host->status("Sending the screen at " + std::to_string(dw) + "x" + std::to_string(dh) + ".");
            }
        }
        frameIndex++;
    }
    encoder.reset();
    if (staging) staging->Release();
    if (dup) dup->Release();
    if (output1) output1->Release();
    output->Release();
    adapter->Release();
    dxgiDevice->Release();
    context->Release();
    device->Release();
    CoUninitialize();
}

void sendPCM(Host* host, const uint8_t* pcm, int bytes, uint16_t rate, uint8_t channels) {
    std::vector<uint8_t> packet(4 + 11 + bytes);
    uint32_t outer = (uint32_t)(11 + bytes);
    uint32_t magic = kAudioMagic;
    uint32_t payload = (uint32_t)bytes;
    memcpy(packet.data(), &outer, 4);
    memcpy(packet.data() + 4, &magic, 4);
    memcpy(packet.data() + 8, &payload, 4);
    memcpy(packet.data() + 12, &rate, 2);
    packet[14] = channels;
    memcpy(packet.data() + 15, pcm, bytes);
    std::lock_guard<std::mutex> lock(host->clientMu);
    for (auto it = host->audioClients.begin(); it != host->audioClients.end();) {
        if (!sendAll(it->sock, packet.data(), (int)packet.size())) {
            closesocket(it->sock);
            it = host->audioClients.erase(it);
            continue;
        }
        ++it;
    }
}

void audioLoop(Host* host) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    IMMDeviceEnumerator* enumerator = nullptr;
    HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
    if (FAILED(hr)) {
        host->status("Audio capture is unavailable. Video will still stream.");
        CoUninitialize();
        return;
    }
    IMMDevice* device = nullptr;
    if (FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device)) || !device) {
        host->status("No playback device found. Video will still stream.");
        enumerator->Release();
        CoUninitialize();
        return;
    }
    IAudioClient* client = nullptr;
    device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)&client);
    if (!client) {
        host->status("Could not tap system audio. Video will still stream.");
        device->Release();
        enumerator->Release();
        CoUninitialize();
        return;
    }
    WAVEFORMATEX* mix = nullptr;
    client->GetMixFormat(&mix);
    hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, 0, 0, mix, nullptr);
    if (FAILED(hr)) {
        host->status("Could not tap system audio. Video will still stream.");
        CoTaskMemFree(mix);
        client->Release();
        device->Release();
        enumerator->Release();
        CoUninitialize();
        return;
    }
    IAudioCaptureClient* capture = nullptr;
    client->GetService(IID_PPV_ARGS(&capture));
    client->Start();
    bool isFloat = mix->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
    if (mix->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
        auto* ext = reinterpret_cast<WAVEFORMATEXTENSIBLE*>(mix);
        isFloat = ext->SubFormat.Data1 == 3;
    }
    int channels = mix->nChannels;
    int rate = mix->nSamplesPerSec;
    std::vector<uint8_t> pending;
    while (host->running.load()) {
        UINT32 packet = 0;
        if (FAILED(capture->GetNextPacketSize(&packet))) break;
        if (packet == 0) {
            Sleep(5);
            continue;
        }
        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        if (FAILED(capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr))) break;
        int samples = (int)frames * channels;
        std::vector<int16_t> pcm((size_t)frames * 2);
        for (UINT32 frame = 0; frame < frames; frame++) {
            for (int ch = 0; ch < 2; ch++) {
                int srcCh = ch < channels ? ch : 0;
                float sample = 0;
                if (flags & AUDCLNT_BUFFERFLAGS_SILENT) sample = 0;
                else if (isFloat) sample = reinterpret_cast<float*>(data)[frame * channels + srcCh];
                else sample = reinterpret_cast<int16_t*>(data)[frame * channels + srcCh] / 32768.f;
                if (sample > 1) sample = 1;
                if (sample < -1) sample = -1;
                pcm[frame * 2 + ch] = (int16_t)(sample * 32767.f);
            }
        }
        capture->ReleaseBuffer(frames);
        if (rate == 48000) {
            pending.insert(pending.end(), (uint8_t*)pcm.data(), (uint8_t*)pcm.data() + pcm.size() * 2);
        } else {
            int outFrames = (int)((int64_t)frames * 48000 / rate);
            if (outFrames < 1) outFrames = 1;
            std::vector<int16_t> resampled((size_t)outFrames * 2);
            for (int i = 0; i < outFrames; i++) {
                int src = (int)((int64_t)i * frames / outFrames);
                if (src >= (int)frames) src = (int)frames - 1;
                resampled[i * 2] = pcm[src * 2];
                resampled[i * 2 + 1] = pcm[src * 2 + 1];
            }
            pending.insert(pending.end(), (uint8_t*)resampled.data(), (uint8_t*)resampled.data() + resampled.size() * 2);
        }
        while (pending.size() >= 1920) {
            sendPCM(host, pending.data(), 1920, 48000, 2);
            pending.erase(pending.begin(), pending.begin() + 1920);
        }
    }
    client->Stop();
    capture->Release();
    client->Release();
    device->Release();
    enumerator->Release();
    CoTaskMemFree(mix);
    CoUninitialize();
}

void closeListen(SOCKET& sock) {
    if (sock != INVALID_SOCKET) {
        closesocket(sock);
        sock = INVALID_SOCKET;
    }
}

}  // namespace

bool gbearHostStart(const GBearHostCallbacks& callbacks, std::string& error) {
    if (gHost) {
        error = "Already hosting.";
        return false;
    }
    auto* host = new Host();
    host->cb = callbacks;
    host->vigem = vigem_alloc();
    if (host->vigem && vigem_connect(host->vigem) == VIGEM_ERROR_NONE) host->vigemReady = true;
    else host->status("ViGEmBus is not installed, so a Mac player's controller cannot reach games yet. Video can still stream. Install ViGEmBus from the ViGEmBus releases, then click Host again.");
    host->httpListen = listenTCP(kControlPort);
    host->videoListen = listenTCP(kVideoPort);
    host->audioListen = listenTCP(kAudioPort);
    host->inputSock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    sockaddr_in inputAddr{};
    inputAddr.sin_family = AF_INET;
    inputAddr.sin_addr.s_addr = htonl(INADDR_ANY);
    inputAddr.sin_port = htons(kInputPort);
    if (host->httpListen == INVALID_SOCKET || host->videoListen == INVALID_SOCKET || host->audioListen == INVALID_SOCKET ||
        host->inputSock == INVALID_SOCKET || bind(host->inputSock, (sockaddr*)&inputAddr, sizeof(inputAddr)) != 0) {
        error = "Could not open GBear ports 28765-28769. Another GBear host may already be running.";
        closeListen(host->httpListen);
        closeListen(host->videoListen);
        closeListen(host->audioListen);
        if (host->inputSock != INVALID_SOCKET) closesocket(host->inputSock);
        if (host->vigem) {
            if (host->vigemReady) vigem_disconnect(host->vigem);
            vigem_free(host->vigem);
        }
        delete host;
        return false;
    }
    DWORD timeout = 200;
    setsockopt(host->inputSock, SOL_SOCKET, SO_RCVTIMEO, (char*)&timeout, sizeof(timeout));
    host->running.store(true);
    gHost = host;
    host->httpThread = std::thread(httpLoop, host);
    host->videoAcceptThread = std::thread(videoAcceptLoop, host);
    host->audioAcceptThread = std::thread(audioAcceptLoop, host);
    host->inputThread = std::thread(inputLoop, host);
    host->captureThread = std::thread(captureLoop, host);
    host->audioThread = std::thread(audioLoop, host);
    host->status("Hosting at " + host->ipv4List() + ". On the Mac: Streaming, Join another computer, enter this IP, Pair & join. You are Player 1. Allow the Windows firewall prompt.");
    return true;
}

void gbearHostApprove(const std::string& deviceId) {
    if (!gHost || deviceId.empty()) return;
    std::lock_guard<std::mutex> lock(gHost->stateMu);
    auto pending = gHost->pending.find(deviceId);
    if (pending == gHost->pending.end()) return;
    gHost->paired[deviceId] = pending->second;
    gHost->pending.erase(pending);
}

void gbearHostStop() {
    Host* host = gHost;
    if (!host) return;
    gHost = nullptr;
    host->running.store(false);
    closeListen(host->httpListen);
    closeListen(host->videoListen);
    closeListen(host->audioListen);
    if (host->inputSock != INVALID_SOCKET) {
        closesocket(host->inputSock);
        host->inputSock = INVALID_SOCKET;
    }
    if (host->httpThread.joinable()) host->httpThread.join();
    if (host->videoAcceptThread.joinable()) host->videoAcceptThread.join();
    if (host->audioAcceptThread.joinable()) host->audioAcceptThread.join();
    if (host->inputThread.joinable()) host->inputThread.join();
    if (host->captureThread.joinable()) host->captureThread.join();
    if (host->audioThread.joinable()) host->audioThread.join();
    {
        std::lock_guard<std::mutex> lock(host->clientMu);
        for (auto& client : host->videoClients) closesocket(client.sock);
        for (auto& client : host->audioClients) closesocket(client.sock);
        host->videoClients.clear();
        host->audioClients.clear();
    }
    {
        std::lock_guard<std::mutex> lock(host->vigemMu);
        for (auto& pad : host->pads) {
            if (host->vigem && pad.second.target) {
                vigem_target_remove(host->vigem, pad.second.target);
                vigem_target_free(pad.second.target);
            }
        }
        host->pads.clear();
        if (host->vigem) {
            if (host->vigemReady) vigem_disconnect(host->vigem);
            vigem_free(host->vigem);
            host->vigem = nullptr;
        }
    }
    delete host;
}
