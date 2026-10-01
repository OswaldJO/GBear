#ifndef GBearHIDUserDevice_h
#define GBearHIDUserDevice_h

#include <CoreFoundation/CoreFoundation.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *GBearHIDDeviceRef;

/// Virtual DualShock 4 named "GBear Virtual Pad <seat>". NULL without the Virtual HID entitlement.
GBearHIDDeviceRef GBearHIDDeviceCreate(int seat);
void GBearHIDDeviceDestroy(GBearHIDDeviceRef device);
/// `report` is a 64-byte DS4 USB input report starting with report ID 0x01.
int GBearHIDDeviceSendReport(GBearHIDDeviceRef device, const uint8_t *report, size_t length);
/// 1 when this process is signed with `com.apple.developer.hid.virtual.device`.
int GBearHIDHasVirtualDeviceEntitlement(void);

#ifdef __cplusplus
}
#endif

#endif
