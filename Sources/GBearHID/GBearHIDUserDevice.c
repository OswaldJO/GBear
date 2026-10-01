#include "GBearHIDUserDevice.h"

#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hidsystem/IOHIDUserDevice.h>
#include <Security/SecTask.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Each pad presents as a wired DualShock 4 (054C:09CC) so SDL, RPCS3, RetroArch and
 * GameController-based apps recognize and auto-map it without per-emulator setup. Report 0x01 is
 * the DS4's 64-byte USB input report; the feature reports below are the ones those libraries
 * request while opening a DS4 (calibration, serial/MAC, firmware info). */
static const uint8_t kDualShock4Descriptor[] = {
    0x05, 0x01, 0x09, 0x05, 0xA1, 0x01,
    0x85, 0x01,
    /* Left X/Y, right X/Y */
    0x09, 0x30, 0x09, 0x31, 0x09, 0x32, 0x09, 0x35,
    0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x04, 0x81, 0x02,
    /* Hat (8 = centered) */
    0x09, 0x39, 0x15, 0x00, 0x25, 0x07, 0x35, 0x00, 0x46, 0x3B, 0x01, 0x65, 0x14,
    0x75, 0x04, 0x95, 0x01, 0x81, 0x42,
    0x65, 0x00,
    /* 14 buttons: Square Cross Circle Triangle L1 R1 L2 R2 Share Options L3 R3 PS Touchpad */
    0x05, 0x09, 0x19, 0x01, 0x29, 0x0E, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x0E, 0x81, 0x02,
    /* 6-bit report counter */
    0x06, 0x00, 0xFF, 0x09, 0x20, 0x75, 0x06, 0x95, 0x01, 0x15, 0x00, 0x25, 0x7F, 0x81, 0x02,
    /* L2 / R2 analog */
    0x05, 0x01, 0x09, 0x33, 0x09, 0x34, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x02, 0x81, 0x02,
    /* Timestamp, motion, battery, touchpad */
    0x06, 0x00, 0xFF, 0x09, 0x21, 0x95, 0x36, 0x81, 0x02,
    /* Output 0x05: rumble / light bar */
    0x85, 0x05, 0x09, 0x22, 0x95, 0x1F, 0x91, 0x02,
    /* Feature 0x02: motion calibration */
    0x85, 0x02, 0x09, 0x24, 0x95, 0x24, 0xB1, 0x02,
    /* Feature 0x12: pad and host MAC */
    0x85, 0x12, 0x06, 0x02, 0xFF, 0x09, 0x21, 0x95, 0x0F, 0xB1, 0x02,
    /* Feature 0x81: pad MAC */
    0x85, 0x81, 0x06, 0x80, 0xFF, 0x09, 0x21, 0x95, 0x06, 0xB1, 0x02,
    /* Feature 0xA3: firmware info */
    0x85, 0xA3, 0x09, 0x25, 0x95, 0x30, 0xB1, 0x02,
    0xC0,
};

struct GBearHIDDevice {
    IOHIDUserDeviceRef device;
    dispatch_queue_t queue;
    int seat;
};

static void storeInt16(uint8_t *bytes, int offset, int16_t value) {
    bytes[offset] = (uint8_t)(value & 0xFF);
    bytes[offset + 1] = (uint8_t)((value >> 8) & 0xFF);
}

/* Fills a feature report; returns its length (report ID included) or 0 if unknown. */
static CFIndex featureReport(int seat, uint32_t reportID, uint8_t *out, CFIndex capacity) {
    uint8_t report[64];
    CFIndex length = 0;
    memset(report, 0, sizeof(report));
    report[0] = (uint8_t)reportID;
    switch (reportID) {
    case 0x02:
        /* Neutral calibration: zero bias, the usual DS4 gyro/accel ranges. USB order is
         * pitch+ pitch- yaw+ yaw- roll+ roll-, then gyro speed +/-, then accel X/Y/Z +/-. */
        length = 37;
        for (int axis = 0; axis < 3; axis++) {
            storeInt16(report, 7 + axis * 4, 8704);
            storeInt16(report, 9 + axis * 4, -8704);
        }
        storeInt16(report, 19, 540);
        storeInt16(report, 21, 540);
        for (int axis = 0; axis < 3; axis++) {
            storeInt16(report, 23 + axis * 4, 8192);
            storeInt16(report, 25 + axis * 4, -8192);
        }
        break;
    case 0x12:
    case 0x81: {
        /* A distinct MAC per seat lets apps tell eight identical pads apart. */
        const uint8_t mac[6] = { (uint8_t)seat, 0x00, 0x50, 0x42, 0x47, 0x02 };
        length = reportID == 0x12 ? 16 : 7;
        memcpy(report + 1, mac, sizeof(mac));
        if (reportID == 0x12) {
            report[7] = 0x08;
            report[8] = 0x25;
        }
        break;
    }
    case 0xA3:
        length = 49;
        memcpy(report + 1, "Sep 29 2026", 11);
        memcpy(report + 17, "00:00:00", 8);
        break;
    default:
        return 0;
    }
    if (length > capacity) length = capacity;
    memcpy(out, report, (size_t)length);
    return length;
}

static CFNumberRef number(int value) {
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
}

static CFStringRef string(const char *value) {
    return CFStringCreateWithCString(kCFAllocatorDefault, value, kCFStringEncodingUTF8);
}

GBearHIDDeviceRef GBearHIDDeviceCreate(int seat) {
    /* With CreateOnActivate a refused kernel device would only fail at Activate, silently, so an
     * unentitled build must not look like it has a pad. */
    if (!GBearHIDHasVirtualDeviceEntitlement()) return NULL;

    CFDataRef desc = CFDataCreate(kCFAllocatorDefault, kDualShock4Descriptor, (CFIndex)sizeof(kDualShock4Descriptor));
    if (!desc) return NULL;

    char productName[64];
    snprintf(productName, sizeof(productName), "GBear Virtual Pad %d", seat);
    char serial[32];
    snprintf(serial, sizeof(serial), "GBEAR-PAD-%d", seat);

    const void *keys[] = {
        CFSTR(kIOHIDReportDescriptorKey),
        CFSTR(kIOHIDVendorIDKey),
        CFSTR(kIOHIDProductIDKey),
        CFSTR(kIOHIDVersionNumberKey),
        CFSTR(kIOHIDManufacturerKey),
        CFSTR(kIOHIDProductKey),
        CFSTR(kIOHIDSerialNumberKey),
        CFSTR(kIOHIDTransportKey),
        CFSTR(kIOHIDLocationIDKey),
        CFSTR(kIOHIDCountryCodeKey),
    };
    const void *values[] = {
        desc,
        number(0x054C),
        number(0x09CC),
        number(0x0100),
        string("GBear"),
        string(productName),
        string(serial),
        string("USB"),
        number(0x47420000 + seat),
        number(0),
    };
    const CFIndex count = (CFIndex)(sizeof(keys) / sizeof(keys[0]));
    CFDictionaryRef props = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        values,
        count,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    for (CFIndex i = 0; i < count; i++) {
        CFRelease(values[i]);
    }

    /* Create the kernel device only on Activate, after the report handlers are in place. */
    IOHIDUserDeviceRef hid = IOHIDUserDeviceCreateWithProperties(
        kCFAllocatorDefault, props, IOHIDUserDeviceOptionsCreateOnActivate
    );
    CFRelease(props);
    if (!hid) return NULL;

    struct GBearHIDDevice *wrapper = calloc(1, sizeof(struct GBearHIDDevice));
    if (!wrapper) {
        CFRelease(hid);
        return NULL;
    }
    wrapper->device = hid;
    wrapper->seat = seat;
    char qname[64];
    snprintf(qname, sizeof(qname), "com.gbear.hid.%d", seat);
    wrapper->queue = dispatch_queue_create(qname, DISPATCH_QUEUE_SERIAL);
    IOHIDUserDeviceSetDispatchQueue(hid, wrapper->queue);
    IOHIDUserDeviceRegisterGetReportBlock(hid, ^IOReturn(IOHIDReportType type, uint32_t reportID, uint8_t *report, CFIndex *reportLength) {
        if (type != kIOHIDReportTypeFeature || !report || !reportLength) return kIOReturnUnsupported;
        CFIndex length = featureReport(seat, reportID, report, *reportLength);
        if (length == 0) return kIOReturnUnsupported;
        *reportLength = length;
        return kIOReturnSuccess;
    });
    /* Rumble and light-bar output from the emulator is accepted and ignored. */
    IOHIDUserDeviceRegisterSetReportBlock(hid, ^IOReturn(IOHIDReportType type, uint32_t reportID, const uint8_t *report, CFIndex reportLength) {
        (void)type; (void)reportID; (void)report; (void)reportLength;
        return kIOReturnSuccess;
    });
    IOHIDUserDeviceSetCancelHandler(hid, ^{
        /* released in Destroy */
    });
    IOHIDUserDeviceActivate(hid);
    return wrapper;
}

void GBearHIDDeviceDestroy(GBearHIDDeviceRef device) {
    struct GBearHIDDevice *wrapper = (struct GBearHIDDevice *)device;
    if (!wrapper) return;
    if (wrapper->device) {
        IOHIDUserDeviceCancel(wrapper->device);
        CFRelease(wrapper->device);
        wrapper->device = NULL;
    }
    if (wrapper->queue) {
#if !OS_OBJECT_USE_OBJC
        dispatch_release(wrapper->queue);
#endif
        wrapper->queue = NULL;
    }
    free(wrapper);
}

int GBearHIDDeviceSendReport(GBearHIDDeviceRef device, const uint8_t *report, size_t length) {
    struct GBearHIDDevice *wrapper = (struct GBearHIDDevice *)device;
    if (!wrapper || !wrapper->device || !report || length == 0) return -1;
    IOReturn result = IOHIDUserDeviceHandleReportWithTimeStamp(
        wrapper->device,
        mach_absolute_time(),
        (uint8_t *)report,
        (CFIndex)length
    );
    return result == kIOReturnSuccess ? 0 : (int)result;
}

int GBearHIDHasVirtualDeviceEntitlement(void) {
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) return 0;
    CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.developer.hid.virtual.device"), NULL);
    CFRelease(task);
    int entitled = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)value);
    if (value) CFRelease(value);
    return entitled;
}
