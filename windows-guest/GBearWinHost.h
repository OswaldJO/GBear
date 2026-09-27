#pragma once

#include <functional>
#include <string>

// Windows-side GBear host. A Mac joins with Streaming → Join another computer.
struct GBearHostCallbacks {
    std::function<void(const std::string& text)> onStatus;
    std::function<void(const std::string& deviceId, const std::string& name)> onPairRequest;
};

bool gbearHostStart(const GBearHostCallbacks& callbacks, std::string& error);
void gbearHostStop();
void gbearHostApprove(const std::string& deviceId);
