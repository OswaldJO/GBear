#ifndef GBearHIDUserDevice_h
#define GBearHIDUserDevice_h

#include <CoreFoundation/CoreFoundation.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *GBearHIDDeviceRef;

GBearHIDDeviceRef GBearHIDDeviceCreate(int seat, const uint8_t *descriptor, size_t descriptorLength);
void GBearHIDDeviceDestroy(GBearHIDDeviceRef device);
int GBearHIDDeviceSendReport(GBearHIDDeviceRef device, const uint8_t *report, size_t length);

#ifdef __cplusplus
}
#endif

#endif
