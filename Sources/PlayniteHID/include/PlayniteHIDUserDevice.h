#ifndef PlayniteHIDUserDevice_h
#define PlayniteHIDUserDevice_h

#include <CoreFoundation/CoreFoundation.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *PlayniteHIDDeviceRef;

PlayniteHIDDeviceRef PlayniteHIDDeviceCreate(int seat, const uint8_t *descriptor, size_t descriptorLength);
void PlayniteHIDDeviceDestroy(PlayniteHIDDeviceRef device);
int PlayniteHIDDeviceSendReport(PlayniteHIDDeviceRef device, const uint8_t *report, size_t length);

#ifdef __cplusplus
}
#endif

#endif
