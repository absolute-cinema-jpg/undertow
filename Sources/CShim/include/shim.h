#ifndef UNDERTOW_SHIM_H
#define UNDERTOW_SHIM_H

#include <stdint.h>
#include <sys/types.h>

typedef struct {
    char name[32];
    uint64_t rx;
    uint64_t tx;
    uint32_t flags;
} un_if_counter;

/// Fills `out` with 64-bit byte counters per interface. getifaddrs() only exposes
/// 32-bit counters, which wrap every 4 GB. Returns the number of entries written.
int un_read_if_counters(un_if_counter *out, int max);

/// Full executable path for a pid. Returns the length, or 0 if the process is gone.
int un_proc_path(pid_t pid, char *buf, uint32_t size);

/// Short process name for a pid. Returns the length, or 0 if the process is gone.
int un_proc_name(pid_t pid, char *buf, uint32_t size);

/// The process macOS holds responsible for `pid` (e.g. Safari for its WebKit
/// networking XPC service). Returns `pid` itself when unavailable.
pid_t un_responsible_pid(pid_t pid);

/// Every running pid. Returns the number written to `out`.
int un_list_pids(pid_t *out, int max);

/// Parent pid, or -1 if the process is gone.
pid_t un_parent_pid(pid_t pid);

#endif
