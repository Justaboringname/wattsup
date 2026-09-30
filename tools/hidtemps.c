// 列出所有 IOHID 温度传感器的名字和当前值
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <stdio.h>
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
extern double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
int main(void) {
    IOHIDEventSystemClientRef sys = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    int page = 0xff00, usage = 5;
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page), u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *k[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")}, *v[] = {p, u};
    CFDictionaryRef m = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(sys, m);
    CFArrayRef svcs = IOHIDEventSystemClientCopyServices(sys);
    for (CFIndex i = 0; svcs && i < CFArrayGetCount(svcs); i++) {
        IOHIDServiceClientRef s = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(svcs, i);
        CFStringRef name = IOHIDServiceClientCopyProperty(s, CFSTR("Product"));
        char buf[128] = "?"; if (name) CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8);
        IOHIDEventRef e = IOHIDServiceClientCopyEvent(s, 15, 0, 0);
        double t = e ? IOHIDEventGetFloatValue(e, 15 << 16) : -1;
        printf("%-28s %6.1f\n", buf, t);
    }
    return 0;
}
