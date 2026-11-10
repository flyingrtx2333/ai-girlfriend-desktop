#ifndef BlueFatFishTerminalPTY_h
#define BlueFatFishTerminalPTY_h

#include <sys/types.h>
#include <sys/ioctl.h>

pid_t bluefatfish_open_terminal(int *master, const char *directory, const char *shell,
                               char *const argv[], char *const environment[], struct winsize size);
void bluefatfish_stop_terminal_session(pid_t leader);

#endif
