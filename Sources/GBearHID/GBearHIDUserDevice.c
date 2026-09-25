#include "GBearHIDUserDevice.h"

#include <IOKit/hidsystem/IOHIDUserDevice.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct GBearHIDDevice {
    IOHIDUserDeviceRef device;
    dispatch_queue_t queue;
};

GBearHIDDeviceRef GBearHIDDeviceCreate(int seat, const uint8_t *descriptor, size_t descriptorLength) {
    if (!descriptor || descriptorLength == 0) return NULL;

    CFDataRef desc = CFDataCreate(kCFAllocatorDefault, descriptor, (CFIndex)descriptorLength);
    if (!desc) return NULL;

    int vendor = 0x1209;
    int product = 0xBEA0 + seat;
    CFNumberRef vendorRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vendor);
    CFNumberRef productRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &product);
    CFStringRef mfg = CFStringCreateWithCString(kCFAllocatorDefault, "GBear", kCFStringEncodingUTF8);
    char productName[64];
    snprintf(productName, sizeof(productName), "GBear Virtual Pad %d", seat);
    CFStringRef prod = CFStringCreateWithCString(kCFAllocatorDefault, productName, kCFStringEncodingUTF8);

    const void *keys[] = {
        CFSTR(kIOHIDReportDescriptorKey),
        CFSTR(kIOHIDVendorIDKey),
        CFSTR(kIOHIDProductIDKey),
        CFSTR(kIOHIDManufacturerKey),
        CFSTR(kIOHIDProductKey),
    };
    const void *values[] = { desc, vendorRef, productRef, mfg, prod };
    CFDictionaryRef props = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        values,
        5,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );

    IOHIDUserDeviceRef hid = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, props, 0);
    CFRelease(props);
    CFRelease(desc);
    CFRelease(vendorRef);
    CFRelease(productRef);
    CFRelease(mfg);
    CFRelease(prod);

    if (!hid) return NULL;

    struct GBearHIDDevice *wrapper = calloc(1, sizeof(struct GBearHIDDevice));
    if (!wrapper) {
        CFRelease(hid);
        return NULL;
    }
    wrapper->device = hid;
    char qname[64];
    snprintf(qname, sizeof(qname), "com.gbear.hid.%d", seat);
    wrapper->queue = dispatch_queue_create(qname, DISPATCH_QUEUE_SERIAL);
    IOHIDUserDeviceSetDispatchQueue(hid, wrapper->queue);
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
