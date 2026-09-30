// 读 IOReport "SoC Stats" 组里所有 *_THROTTLE_*_TRIG 计数器，每 <间隔> 秒打印一次有变化的增量，结束时打印总增量。
//   throttlewatch <秒> <间隔>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;
extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);
extern int IOReportChannelGetFormat(CFDictionaryRef);
extern int32_t IOReportStateGetCount(CFDictionaryRef);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);
static int shown_states;

#define MAXC 512
static char names[MAXC][64]; static long long total[MAXC], span[MAXC]; static int nnames;
static int idx(const char *n) { for (int i = 0; i < nnames; i++) if (!strcmp(names[i], n)) return i;
    if (nnames < MAXC) { strlcpy(names[nnames], n, 64); return nnames++; } return -1; }

int main(int c, char **v) {
    int secs = atoi(v[1]); double iv = atof(v[2]);
    CFDictionaryRef ch = IOReportCopyChannelsInGroup(CFSTR("SoC Stats"), NULL, 0, 0, 0);
    if (!ch) { fprintf(stderr, "no SoC Stats group\n"); return 1; }
    CFMutableDictionaryRef mch = CFDictionaryCreateMutableCopy(NULL, 0, ch), sub_ch = NULL;
    IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL, mch, &sub_ch, 0, NULL);
    if (!sub) { fprintf(stderr, "subscription failed\n"); return 1; }
    CFDictionaryRef prev = IOReportCreateSamples(sub, sub_ch, NULL);
    int nch = 0;
    for (double t = 0; t < secs; t += iv) {
        usleep((useconds_t)(iv * 1e6));
        CFDictionaryRef cur = IOReportCreateSamples(sub, sub_ch, NULL);
        CFDictionaryRef d = IOReportCreateSamplesDelta(prev, cur, NULL);
        CFRelease(prev); prev = cur;
        CFArrayRef arr = CFDictionaryGetValue(d, CFSTR("IOReportChannels"));
        char line[4096] = ""; nch = (int)CFArrayGetCount(arr);
        for (CFIndex i = 0; i < CFArrayGetCount(arr); i++) {
            CFDictionaryRef e = CFArrayGetValueAtIndex(arr, i);
            char n[64]; CFStringGetCString(IOReportChannelGetChannelName(e), n, sizeof n, kCFStringEncodingUTF8);
            if (!strstr(n, "THROTTLE") && !strstr(n, "SOCHOT")) continue;
            // 两态通道：第 0 态是没触发，其余是触发中；记触发态占的驻留比例
            if (IOReportChannelGetFormat(e) != 2) continue;
            int ns = IOReportStateGetCount(e);
            if (!shown_states) { shown_states = 1; printf("states:"); for (int q = 0; q < ns; q++) { char sn[32] = ""; CFStringRef x = IOReportStateGetNameForIndex(e, q); if (x) CFStringGetCString(x, sn, sizeof sn, kCFStringEncodingUTF8); printf(" [%d]=%s", q, sn); } printf("\n"); }
            long long all = 0, on = 0;
            for (int q = 0; q < ns; q++) { long long r = IOReportStateGetResidency(e, q); all += r; if (q) on += r; }
            if (!on) continue;
            int k = idx(n); if (k >= 0) { total[k] += on; span[k] += all; }
            char tmp[96]; snprintf(tmp, sizeof tmp, " %s=%.1f%%", n, all ? 100.0 * on / all : 0);
            if (strlen(line) + strlen(tmp) < sizeof line) strcat(line, tmp);
        }
        printf("t=%5.1fs%s\n", t + iv, line[0] ? line : " (none)"); fflush(stdout);
        CFRelease(d);
    }
    printf("TOTAL over %ds (%d channels in group):\n", secs, nch);
    for (int i = 0; i < nnames; i++) printf("  %-28s active residency %lld (%.1f%% of the intervals it appeared in)\n", names[i], total[i], span[i] ? 100.0 * total[i] / span[i] : 0);
    return 0;
}
