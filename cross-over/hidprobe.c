// Native IOHIDManager probe — the SAME raw-HID access class Wine's winebus uses.
// Purpose: determine empirically whether ANY raw-HID client on this Mac can read
// input reports from the Xbox controller, or whether Apple's XboxGamepad.dext /
// gamecontrollerd has seized it exclusively (or Input Monitoring gates it).
//
// Build:  clang hidprobe.c -o hidprobe -framework IOKit -framework CoreFoundation
// Run:    ./hidprobe            (matches any game pad, usage page 1 / usage 5)
// Move the left stick / press buttons for the 12s window.
//
// Interpreting:
//   OPEN_OK + report lines            -> raw HID works; Wine/CrossOver CAN read it
//                                        (once CrossOver has Input Monitoring).
//   OPEN_OK + zero reports            -> enumerated but seized elsewhere / perms gate.
//   OPEN_FAILED (exclusive access)    -> gamecontrollerd holds it exclusively.

#include <IOKit/hid/IOHIDManager.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>

static int g_reports = 0;

static void input_cb(void *ctx, IOReturn res, void *sender, IOHIDValueRef value) {
    IOHIDElementRef el = IOHIDValueGetElement(value);
    uint32_t usagePage = IOHIDElementGetUsagePage(el);
    uint32_t usage     = IOHIDElementGetUsage(el);
    CFIndex  ival      = IOHIDValueGetIntegerValue(value);
    g_reports++;
    if (g_reports <= 60) // don't spam
        printf("  report #%d  usagePage=0x%02x usage=0x%02x value=%ld\n",
               g_reports, usagePage, usage, (long)ival);
}

static void matched_cb(void *ctx, IOReturn res, void *sender, IOHIDDeviceRef dev) {
    CFStringRef p = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDProductKey));
    char buf[256] = "?";
    if (p) CFStringGetCString(p, buf, sizeof buf, kCFStringEncodingUTF8);
    CFNumberRef v = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDVendorIDKey));
    int vid = 0; if (v) CFNumberGetValue(v, kCFNumberIntType, &vid);
    printf("MATCHED device: \"%s\" (VID 0x%04x)\n", buf, vid);
}

int main(void) {
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);

    // Match Generic Desktop (0x01) Game Pad (0x05) and Joystick (0x04).
    const int pairs[][2] = {{1,5},{1,4}};
    CFMutableArrayRef arr = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    for (int i = 0; i < 2; i++) {
        CFMutableDictionaryRef d = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFNumberRef up = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pairs[i][0]);
        CFNumberRef u  = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pairs[i][1]);
        CFDictionarySetValue(d, CFSTR(kIOHIDDeviceUsagePageKey), up);
        CFDictionarySetValue(d, CFSTR(kIOHIDDeviceUsageKey), u);
        CFArrayAppendValue(arr, d);
        CFRelease(up); CFRelease(u); CFRelease(d);
    }
    IOHIDManagerSetDeviceMatchingMultiple(mgr, arr);
    CFRelease(arr);

    IOHIDManagerRegisterDeviceMatchingCallback(mgr, matched_cb, NULL);
    IOHIDManagerRegisterInputValueCallback(mgr, input_cb, NULL);
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    IOReturn r = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) {
        printf("OPEN_FAILED: IOHIDManagerOpen returned 0x%08x "
               "(likely seized exclusively by gamecontrollerd)\n", r);
        return 1;
    }
    printf("OPEN_OK. Listening 12s — move the LEFT stick / press buttons now...\n");

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 12.0, false);

    printf("\nTOTAL input reports received: %d\n", g_reports);
    if (g_reports == 0)
        printf("VERDICT: enumerated + opened but ZERO reports -> device seized elsewhere "
               "or Input Monitoring gates report delivery. Raw-HID (Wine) path is blocked.\n");
    else
        printf("VERDICT: raw HID CAN read this pad -> CrossOver/Wine can too, given the "
               "same access (grant CrossOver Input Monitoring).\n");
    return 0;
}
