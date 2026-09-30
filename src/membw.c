// 内存带宽压力：每个线程在自己的两块 256 MB 缓冲区之间做 a[i] = b[i] * s + a[i](读 2 写 1)。
//   membw <秒> <线程数>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#define N (32u << 20)  // 32M doubles = 256 MB
static double secs; static volatile double sink;
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static void *work(void *arg) {
    double *a = malloc(N * sizeof(double)), *b = malloc(N * sizeof(double));
    for (size_t i = 0; i < N; i++) { a[i] = i * 1e-9; b[i] = 1.0 / (i + 1); }
    double t0 = now(); long passes = 0;
    while (now() - t0 < secs) { for (size_t i = 0; i < N; i++) a[i] = b[i] * 1.0000001 + a[i]; passes++; }
    sink += a[N / 2];
    *(double *)arg = passes * 3.0 * N * sizeof(double) / (now() - t0) / 1e9;
    free(a); free(b); return NULL;
}
int main(int c, char **v) {
    secs = atof(v[1]); int n = atoi(v[2]);
    pthread_t th[64]; double gbs[64];
    for (int i = 0; i < n; i++) pthread_create(&th[i], NULL, work, &gbs[i]);
    double tot = 0; for (int i = 0; i < n; i++) { pthread_join(th[i], NULL); tot += gbs[i]; }
    printf("membw %d threads: %.0f GB/s\n", n, tot);
    return 0;
}
