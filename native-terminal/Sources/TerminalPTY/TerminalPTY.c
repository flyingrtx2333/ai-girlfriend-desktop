#include "TerminalPTY.h"
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

pid_t bluefatfish_open_terminal(int *master, const char *directory, const char *shell,
                               char *const argv[], char *const environment[], struct winsize size) {
    int workdir = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (workdir < 0) return -1;
    if (workdir <= STDERR_FILENO) {
        int duplicate = fcntl(workdir, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
        int error = errno;
        close(workdir);
        if (duplicate < 0) {
            errno = error;
            return -1;
        }
        workdir = duplicate;
    }

    pid_t child = forkpty(master, NULL, NULL, &size);
    if (child == 0) {
        // Keep the child on async-signal-safe calls until exec.
        if (fchdir(workdir) != 0) {
            static const char message[] = "Cannot open terminal working directory.\n";
            write(STDERR_FILENO, message, sizeof(message) - 1);
            _exit(125);
        }
        close(workdir);
        const int signals[] = { SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE, SIGTSTP, SIGTTIN, SIGTTOU, SIGCHLD };
        struct sigaction action = { .sa_handler = SIG_DFL };
        sigemptyset(&action.sa_mask);
        for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i) sigaction(signals[i], &action, NULL);
        sigprocmask(SIG_SETMASK, &action.sa_mask, NULL);
        execve(shell, argv, environment);
        static const char message[] = "Cannot start terminal shell.\n";
        write(STDERR_FILENO, message, sizeof(message) - 1);
        _exit(127);
    }

    int error = errno;
    close(workdir);
    if (child < 0) {
        errno = error;
        return -1;
    }
    if (fcntl(*master, F_SETFD, FD_CLOEXEC) == -1) {
        error = errno;
        kill(child, SIGKILL);
        close(*master);
        while (waitpid(child, NULL, 0) == -1 && errno == EINTR) {}
        errno = error;
        return -1;
    }
    return child;
}

void bluefatfish_stop_terminal_session(pid_t leader) {
    if (leader <= 0) return;
    // An interactive shell gives foreground and background jobs separate
    // process groups. Match its session before the parent reaps the leader.
    kill(leader, SIGKILL);
    int count = proc_listallpids(NULL, 0);
    if (count <= 0) return;
    count += 64;
    pid_t *processes = calloc((size_t)count, sizeof(*processes));
    if (!processes) return;
    int found = proc_listallpids(processes, (int)(count * sizeof(*processes)));
    for (int i = 0; i < found; ++i) {
        pid_t process = processes[i];
        if (process > 0 && process != leader && getsid(process) == leader) kill(process, SIGKILL);
    }
    free(processes);
}
