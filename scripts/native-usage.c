#include <libproc.h>
#include <sys/resource.h>
#include <stdio.h>
#include <stdlib.h>
#include <mach/mach_time.h>

// Read-only process counters; CPU is measured from two samples by the caller.
int main(int argc, char **argv) {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    for (int i = 1; i < argc; i++) {
        int pid = atoi(argv[i]);
        struct rusage_info_v4 usage = {0};
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) { perror("proc_pid_rusage"); return 1; }
        double cpu = (usage.ri_user_time + usage.ri_system_time) * (double)timebase.numer / timebase.denom;
        printf("{\"pid\":%d,\"footprint\":%llu,\"rss\":%llu,\"cpuNanoseconds\":%.0f,\"wakeups\":%llu}\n",
               pid, usage.ri_phys_footprint, usage.ri_resident_size, cpu, usage.ri_interrupt_wkups);
    }
    return 0;
}
