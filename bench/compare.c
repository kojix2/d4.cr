#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "d4.h"

int main(int argc, char **argv) {
    if (argc < 4) return 2;
    const char *mode = argv[1], *path = argv[2];
    uint64_t length = strtoull(argv[3], NULL, 10);
    if (strcmp(mode, "generate-dual") == 0) {
        char *names[] = {"chr1", "chr2"};
        uint32_t sizes[] = {(uint32_t)length, (uint32_t)length};
        d4_file_metadata_t metadata = {.chrom_count = 2, .chrom_name = names,
            .chrom_size = sizes, .dict_type = D4_DICT_SIMPLE_RANGE, .denominator = 1.0,
            .dict_data.simple_range = {.low = 0, .high = 8}};
        d4_file_t *writer = d4_open(path, "w");
        if (!writer || d4_file_update_metadata(writer, &metadata) != 0) return 7;
        int32_t values[65536];
        for (int chrom = 0; chrom < 2; ++chrom) {
            for (uint64_t offset = 0; offset < length;) {
                size_t request = length - offset < 65536 ? (size_t)(length - offset) : 65536;
                for (size_t i = 0; i < request; ++i) values[i] = (int32_t)((offset + i) % 8);
                if (d4_file_write_values(writer, values, request) != (ssize_t)request) return 8;
                offset += request;
            }
        }
        return d4_close(writer) == 0 ? 0 : 9;
    }
    if (strcmp(mode, "generate") == 0 && argc >= 5) {
        char *names[] = {"chr"};
        uint32_t sizes[] = {(uint32_t)length};
        int alternate = strcmp(argv[4], "alternate") == 0;
        d4_file_metadata_t metadata = {.chrom_count = 1, .chrom_name = names,
            .chrom_size = sizes, .dict_type = D4_DICT_SIMPLE_RANGE, .denominator = 1.0,
            .dict_data.simple_range = {.low = 0, .high = alternate ? 1 : 8}};
        d4_file_t *writer = d4_open(path, "w");
        if (!writer || d4_file_update_metadata(writer, &metadata) != 0) return 7;
        int32_t values[65536];
        for (uint64_t offset = 0; offset < length;) {
            size_t request = length - offset < 65536 ? (size_t)(length - offset) : 65536;
            for (size_t i = 0; i < request; ++i) {
                uint64_t pos = offset + i;
                values[i] = alternate ? (int32_t)(1 + pos % 2) :
                    strcmp(argv[4], "sparse") == 0 && pos % 100 == 0 ? 100 : (int32_t)(pos % 8);
            }
            ssize_t done = d4_file_write_values(writer, values, request);
            if (done != (ssize_t)request) { fprintf(stderr, "short write: %zd\n", done); return 8; }
            offset += request;
        }
        if (d4_close(writer) != 0) return 9;
        return 0;
    }
    d4_file_t *file = d4_open(path, "r");
    if (!file) { fprintf(stderr, "d4_open failed\n"); return 3; }
    int64_t checksum = 0;
    if (strcmp(mode, "scan-dual") == 0) {
        const char *names[] = {"chr1", "chr2"};
        int32_t values[65536];
        for (int chrom = 0; chrom < 2; ++chrom) {
            if (d4_file_seek(file, names[chrom], 0) != 0) return 10;
            for (uint64_t processed = 0; processed < length;) {
                size_t request = length - processed < 65536 ? (size_t)(length - processed) : 65536;
                ssize_t got = d4_file_read_values(file, values, request);
                if (got <= 0 || (size_t)got > request) return 4;
                for (ssize_t i = 0; i < got; ++i) checksum += values[i];
                processed += got;
            }
        }
        if (d4_close(file) != 0) return 6;
        printf("checksum=%lld\n", (long long)checksum);
        return 0;
    }
    if (strcmp(mode, "scan") == 0 || strcmp(mode, "materialize") == 0) {
        if (argc >= 5 && d4_file_seek(file, argv[4], 0) != 0) return 10;
        int materialize = strcmp(mode, "materialize") == 0;
        int32_t stack_values[65536];
        int32_t *values = materialize ? malloc(length * sizeof(int32_t)) : stack_values;
        if (!values) return 11;
        uint64_t processed = 0;
        while (processed < length) {
            size_t request = length - processed < 65536 ? (size_t)(length - processed) : 65536;
            ssize_t got = d4_file_read_values(file, values + (materialize ? processed : 0), request);
            if (got <= 0 || (size_t)got > request) { fprintf(stderr, "short read at %llu: %zd\n", (unsigned long long)processed, got); return 4; }
            if (!materialize) for (ssize_t i = 0; i < got; ++i) checksum += values[i];
            processed += got;
        }
        if (materialize) {
            for (uint64_t i = 0; i < length; ++i) checksum += values[i];
            free(values);
        }
    } else if (strcmp(mode, "point") == 0 && argc >= 5) {
        uint64_t count = strtoull(argv[4], NULL, 10);
        for (uint64_t i = 0; i < count; ++i) {
            uint32_t position = (uint32_t)((i * 65537) % length);
            int32_t value = 0;
            if (d4_file_seek(file, "chr", position) != 0 || d4_file_read_values(file, &value, 1) != 1) {
                fprintf(stderr, "point read failed at %u\n", position); return 5;
            }
            checksum += value;
        }
    } else return 2;
    if (d4_close(file) != 0) return 6;
    printf("checksum=%lld\n", (long long)checksum);
    return 0;
}
