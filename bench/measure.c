/* Small-parent fork/exec avoids inheriting Python's RSS high-water mark. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static double seconds(const struct timespec *value) {
    return (double)value->tv_sec + (double)value->tv_nsec / 1000000000.0;
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    struct timespec before, after;
    clock_gettime(CLOCK_MONOTONIC, &before);
    pid_t child = fork();
    if (child == 0) { execvp(argv[1], argv + 1); _exit(127); }
    if (child < 0) return 3;
    int status;
    struct rusage usage;
    if (wait4(child, &status, 0, &usage) < 0) return 4;
    clock_gettime(CLOCK_MONOTONIC, &after);
    fprintf(stderr, "measure_ms=%.3f peak_rss_kb=%ld user_ms=%.3f system_ms=%.3f\n",
        (seconds(&after) - seconds(&before)) * 1000.0, usage.ru_maxrss,
        (double)usage.ru_utime.tv_sec * 1000.0 + usage.ru_utime.tv_usec / 1000.0,
        (double)usage.ru_stime.tv_sec * 1000.0 + usage.ru_stime.tv_usec / 1000.0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
