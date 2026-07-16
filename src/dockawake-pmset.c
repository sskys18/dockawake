/*
 * dockawake-pmset: fixed privileged helper for DockAwake.
 * Accepts exactly "on" or "off" and execs /usr/bin/pmset.
 * Installed root:wheel at /Library/PrivilegedHelperTools/dockawake-pmset,
 * invoked via a narrow NOPASSWD sudoers rule. Never invokes a shell.
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "usage: dockawake-pmset on|off\n");
        return 64;
    }
    const char *value;
    if (strcmp(argv[1], "on") == 0) {
        value = "1";
    } else if (strcmp(argv[1], "off") == 0) {
        value = "0";
    } else {
        fprintf(stderr, "invalid mode: %s\n", argv[1]);
        return 64;
    }
    execl("/usr/bin/pmset", "pmset", "-a", "disablesleep", value, (char *)NULL);
    perror("execl");
    return 71;
}
