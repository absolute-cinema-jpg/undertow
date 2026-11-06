#include "shim.h"

#include <dlfcn.h>
#include <libproc.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/sysctl.h>

int un_read_if_counters(un_if_counter *out, int max) {
    int mib[6] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0};
    size_t len = 0;
    if (sysctl(mib, 6, NULL, &len, NULL, 0) != 0) return 0;
    char *buf = malloc(len);
    if (!buf) return 0;
    if (sysctl(mib, 6, buf, &len, NULL, 0) != 0) {
        free(buf);
        return 0;
    }
    int count = 0;
    for (char *p = buf; p < buf + len && count < max;) {
        struct if_msghdr *hdr = (struct if_msghdr *)p;
        if (hdr->ifm_msglen == 0) break;
        if (hdr->ifm_type == RTM_IFINFO2) {
            struct if_msghdr2 *h2 = (struct if_msghdr2 *)hdr;
            char name[IF_NAMESIZE] = {0};
            if (if_indextoname(h2->ifm_index, name)) {
                strlcpy(out[count].name, name, sizeof(out[count].name));
                out[count].rx = h2->ifm_data.ifi_ibytes;
                out[count].tx = h2->ifm_data.ifi_obytes;
                out[count].flags = (uint32_t)h2->ifm_flags;
                count++;
            }
        }
        p += hdr->ifm_msglen;
    }
    free(buf);
    return count;
}

int un_proc_path(pid_t pid, char *buf, uint32_t size) {
    return proc_pidpath(pid, buf, size);
}

int un_proc_name(pid_t pid, char *buf, uint32_t size) {
    return proc_name(pid, buf, size);
}

pid_t un_responsible_pid(pid_t pid) {
    typedef pid_t (*fn_t)(pid_t);
    static fn_t fn = NULL;
    static int looked_up = 0;
    if (!looked_up) {
        fn = (fn_t)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
        looked_up = 1;
    }
    if (!fn) return pid;
    pid_t r = fn(pid);
    return r > 0 ? r : pid;
}

int un_list_pids(pid_t *out, int max) {
    int count = proc_listallpids(out, max * (int)sizeof(pid_t));
    return count > 0 ? count : 0;
}

pid_t un_parent_pid(pid_t pid) {
    struct kinfo_proc info;
    size_t len = sizeof(info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &len, NULL, 0) != 0 || len == 0) return -1;
    return info.kp_eproc.e_ppid;
}
