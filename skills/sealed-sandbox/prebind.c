/* prebind.c: bind an AF_UNIX listener on FD and exec CMD.
 *
 * Usage: prebind SOCK FD CMD...
 * Example: ./prebind ./entry.sock 4 workerd serve --socket-fd=http=4 minimal.capnp
 *
 * WHY THIS EXISTS. This cage refuses bind(2) on AF_INET (EACCES) but permits
 * AF_UNIX, so a program that can adopt an already-listening descriptor
 * (workerd --socket-fd) can serve without ever calling bind itself. The
 * descriptor must land on a CHOSEN number, already LISTENING, and survive
 * exec (FD_CLOEXEC cleared); node:child_process cannot pass a chosen
 * descriptor and reports an unbound socket rather than a descriptor error,
 * which is why this is a 60-line C program and not a shell function.
 * Two obligations come with it: rm -f the path before binding (a bound
 * socket file outlives its process and the next run fails EADDRINUSE with
 * nothing listening), and note that killed processes linger as unreapable
 * zombies here, so pgrep matching a <defunct> is not evidence of a listener.
 *
 * Build: cc -O2 -o prebind prebind.c
 * Fetch: curl -fsSL https://raw.githubusercontent.com/talaria0101/sandhome/main/skills/sealed-sandbox/prebind.c -o prebind.c
 */
#include <sys/socket.h>
#include <sys/un.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: prebind SOCK FD CMD...\n"); return 2; }
    if (strlen(argv[1]) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        fprintf(stderr, "prebind: socket path too long\n"); return 2;
    }
    unlink(argv[1]);
    {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) { perror("socket"); return 1; }
        struct sockaddr_un a;
        memset(&a, 0, sizeof a);
        a.sun_family = AF_UNIX;
        strncpy(a.sun_path, argv[1], sizeof a.sun_path - 1);
        if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0) { perror("bind"); return 1; }
        if (listen(fd, 511) < 0) { perror("listen"); return 1; }
        {
            int slot = atoi(argv[2]);
            if (slot <= 2) { fprintf(stderr, "prebind: refusing fd %d (would replace stdio)\n", slot); return 2; }
            if (fd != slot) {
                if (dup2(fd, slot) < 0) { perror("dup2"); return 1; }
                close(fd);
            }
            {
                int fl = fcntl(slot, F_GETFD);
                if (fl >= 0) fcntl(slot, F_SETFD, fl & ~FD_CLOEXEC);
            }
        }
    }
    execvp(argv[3], &argv[3]);
    perror("execvp");
    return 1;
}
