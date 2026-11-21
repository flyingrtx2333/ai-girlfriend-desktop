#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static int launchFailure(int error)
{
    fprintf(stderr, "无法启动终端进程监控（%d）\n", error);
    return 125;
}

static int number(const char *value)
{
    char *end;
    long parsed = strtol(value, &end, 10);
    return end != value && *end == '\0' && parsed >= 0 && parsed <= INT_MAX ? (int)parsed : -1;
}

static void watchCommand(int queue, int lifetime, pid_t command)
{
    struct kevent watch;
    EV_SET(&watch, command, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    if (kevent(queue, &watch, 1, NULL, 0, NULL) < 0) return;

    for (;;) {
        struct kevent event;
        int count = kevent(queue, NULL, 0, &event, 1, NULL);
        if (count < 0 && errno == EINTR) continue;
        if (count != 1 || event.filter == EVFILT_PROC || (event.flags & (EV_EOF | EV_ERROR))) return;
        char request;
        ssize_t received = read(lifetime, &request, 1);
        if (received < 0 && errno == EINTR) continue;
        if (received != 1) return;
        // A timeout requests TERM first. Closing the pipe (Stop or app exit)
        // always ends the command, including children that ignore TERM.
        kill(-command, SIGTERM);
    }
}

int main(int argc, char *argv[])
{
    bool connector = argc >= 5 && strcmp(argv[3], "--stdio") == 0;
    if (connector ? argv[4][0] != '/' : (argc < 6 || strcmp(argv[3], "-p") != 0)) return launchFailure(EINVAL);
    pid_t owner = number(argv[1]);
    int lifetime = number(argv[2]);
    if (owner <= 1 || owner != getppid() || lifetime <= STDERR_FILENO) return launchFailure(EINVAL);

    int queue = kqueue();
    if (queue < 0 || fcntl(queue, F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(lifetime, F_SETFD, FD_CLOEXEC) < 0) return launchFailure(errno);
    struct kevent watches[2], event;
    struct timespec immediate = {0, 0};
    EV_SET(&watches[0], owner, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    EV_SET(&watches[1], lifetime, EVFILT_READ, EV_ADD, 0, 0, NULL);
    int ready = kevent(queue, watches, 2, &event, 1, &immediate);
    if (ready < 0 || (ready == 1 && (event.flags & EV_ERROR))) return launchFailure(ready < 0 ? errno : (int)event.data);
    if (ready != 0 || owner != getppid()) return 128 + SIGKILL;

    char **invocation = connector ? argv + 4 : argv + 2;
    if (!connector) invocation[0] = "/usr/bin/sandbox-exec";
    posix_spawnattr_t attributes;
    pid_t command;
    int error = posix_spawnattr_init(&attributes);
    if (error != 0) return launchFailure(error);
    error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP);
    if (error == 0) error = posix_spawnattr_setpgroup(&attributes, 0);
    if (error == 0) error = posix_spawn(&command, invocation[0], NULL, &attributes, invocation, environ);
    posix_spawnattr_destroy(&attributes);
    if (error != 0) return launchFailure(error);

    if (connector) {
        // Keep only the lifetime pipe. The connector's streams must report
        // EOF as soon as that program closes them.
        close(STDIN_FILENO);
        close(STDOUT_FILENO);
        close(STDERR_FILENO);
    }
    watchCommand(queue, lifetime, command);
    kill(-command, SIGKILL);
    siginfo_t exited;
    int waited;
    do { waited = waitid(P_PID, (id_t)command, &exited, WEXITED | WNOWAIT); } while (waited < 0 && errno == EINTR);
    // A shell can be forking when the first signal arrives. Stop the group
    // again once its leader is dead, while that unreaped PID still owns the ID.
    if (waited == 0) kill(-command, SIGKILL);
    int status;
    pid_t reaped;
    do { reaped = waitpid(command, &status, 0); } while (reaped < 0 && errno == EINTR);
    if (reaped != command) return launchFailure(errno);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
