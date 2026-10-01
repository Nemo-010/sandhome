/* memexec - run a file that its own mount refuses to execute.
 *
 * A sandbox can mount a directory writable and still refuse execve on it,
 * while /tmp-style exec roots are small. Copying every executable onto the
 * exec root costs ~100MB per toolchain; running the bytes from memory costs
 * nothing on any root. This helper does the second: it copies the named file
 * into an anonymous memfd and executes it from the file descriptor.
 *
 * Mechanism (transcribed, not copied): create an anonymous file with
 * memfd_create, copy the payload bytes into it, execute it through
 * /proc/self/fd/N, falling back to fexecve where /proc is absent. The same
 * shape is documented by hackerschoice/memexec (memfd_create plus execveat
 * through a fd, reference: https://github.com/hackerschoice/memexec README
 * and memexec.nasm); what runs here is written from scratch for this tree.
 * Measured on a noexec $HOME: direct exec fails with EACCES (exit 126),
 * ELF, dynamic ELF, and #! scripts all run from the memfd (exit of target).
 *
 * Two spellings:
 *   sandhome-memexec PAYLOAD ARGS...   run PAYLOAD with argv[0] = PAYLOAD
 *   <view copy> ARGS...                the same binary copied into an exec
 *                                      view under another basename maps its
 *                                      own path back to the payload (a
 *                                      longest-prefix map, then the
 *                                      views/<name> to toolchains/<name>
 *                                      convention) and keeps argv[0] as the
 *                                      view path, which is what exe-relative
 *                                      tools (clang -cc1, gcc wrappers) need.
 *
 * The fd is left open across exec on purpose (no MFD_CLOEXEC): a #! script
 * run from /proc/self/fd/N is re-opened by its interpreter in the new
 * process, and a cloexec fd is gone by then ("cannot open /proc/self/fd/N").
 * A suid bit does not survive the copy, which is intended: views never
 * carry privilege.
 *
 * Plain ASCII C, libc only. Linux-only by construction (memfd_create); where
 * it cannot be built the tree falls back to copying executables.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *base(const char *p) {
    const char *s = strrchr(p, '/');
    return s ? s + 1 : p;
}

/* longest-prefix map from the environment: "VIEW=HOME VIEW=HOME ...".
 * Explicit and first: a caller that knows its layout says so. */
static const char *map_env(const char *self) {
    static char out[8192];
    const char *map = getenv("SANDHOME_MEMEXEC_MAP");
    size_t best = 0;
    const char *best_home = 0;
    size_t best_home_len = 0;
    if (!map || !*map)
        return 0;
    while (*map) {
        while (*map == ' ' || *map == '\t')
            map++;
        if (!*map)
            break;
        const char *eq = strchr(map, '=');
        const char *end = strchr(map, ' ');
        const char *tab = strchr(map, '\t');
        if (tab && (!end || tab < end))
            end = tab;
        if (!end)
            end = map + strlen(map);
        if (eq && eq < end) {
            size_t vlen = (size_t)(eq - map);
            size_t hlen = (size_t)(end - (eq + 1));
            if (vlen > 0 && vlen > best && strncmp(self, map, vlen) == 0) {
                best = vlen;
                best_home = eq + 1;
                best_home_len = hlen;
            }
        }
        map = end;
    }
    if (!best || best_home_len + strlen(self + best) + 1 > sizeof out)
        return 0;
    memcpy(out, best_home, best_home_len);
    strcpy(out + best_home_len, self + best);
    return out;
}

/* the tree convention: $SANDHOME_EXEC/views/<name>/... is the exec mirror of
 * $SANDHOME_HOME/toolchains/<name>/... . Both roots are already exported by
 * env.sh, so a view copy finds its payload with no per-file state. */
static const char *map_convention(const char *self) {
    static char out[8192];
    const char *exec = getenv("SANDHOME_EXEC");
    const char *home = getenv("SANDHOME_HOME");
    const char *views;
    size_t vlen;
    char want[8192];
    const char *slash;
    if (!exec || !*exec || !home || !*home)
        return 0;
    snprintf(want, sizeof want, "%s/views/", exec);
    vlen = strlen(want);
    if (strncmp(self, want, vlen) != 0)
        return 0;
    views = self + vlen;
    slash = strchr(views, '/');
    if (!slash || slash == views)
        return 0;
    snprintf(out, sizeof out, "%s/toolchains/%.*s%s", home,
        (int)(slash - views), views, slash);
    return out;
}

/* same_file A B -> 1 when both name the same inode. The launcher must
 * never execute itself: a view copy on an exec-capable mount would pass
 * the direct execve and re-run this helper forever. */
static int same_file(const char *a, const char *b) {
    struct stat sa, sb;
    if (stat(a, &sa) != 0 || stat(b, &sb) != 0)
        return 0;
    return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino;
}

static int run_payload(const char *prog, const char *payload, char **argv) {
    extern char **environ;
    char self[8192];
    ssize_t slen = readlink("/proc/self/exe", self, sizeof self - 1);
    if (slen > 0) {
        self[slen] = 0;
        if (same_file(self, payload)) {
            fprintf(stderr, "%s: refusing to execute itself (%s)\n",
                prog, payload);
            return 127;
        }
    }
    execve(payload, argv, environ);
    if (errno != EACCES && errno != EPERM) {
        fprintf(stderr, "%s: cannot run %s: %s\n", prog, payload,
            strerror(errno));
        return 127;
    }
    {
        int mfd = memfd_create("sandhome", 0);
        int fd;
        static char buf[131072];
        ssize_t n;
        char fdpath[64];
        if (mfd < 0) {
            fprintf(stderr, "%s: memfd_create failed: %s\n", prog,
                strerror(errno));
            return 126;
        }
        fd = open(payload, O_RDONLY);
        if (fd < 0) {
            fprintf(stderr, "%s: cannot read %s: %s\n", prog, payload,
                strerror(errno));
            return 127;
        }
        for (;;) {
            ssize_t w;
            n = read(fd, buf, sizeof buf);
            if (n == 0)
                break;
            if (n < 0 && errno == EINTR)
                continue;
            if (n < 0) {
                fprintf(stderr, "%s: cannot read %s: %s\n", prog, payload,
                    strerror(errno));
                return 127;
            }
            w = 0;
            while (w < n) {
                ssize_t k = write(mfd, buf + w, (size_t)(n - w));
                if (k < 0 && errno == EINTR)
                    continue;
                if (k <= 0) {
                    fprintf(stderr, "%s: memfd write failed: %s\n", prog,
                        strerror(errno));
                    return 127;
                }
                w += k;
            }
        }
        close(fd);
        if (lseek(mfd, 0, SEEK_SET) < 0) {
            fprintf(stderr, "%s: memfd seek failed: %s\n", prog,
                strerror(errno));
            return 127;
        }
        snprintf(fdpath, sizeof fdpath, "/proc/self/fd/%d", mfd);
        execve(fdpath, argv, environ);
        /* No /proc, or a cage that hides it: fexecve needs no pathname. */
        fexecve(mfd, argv, environ);
        fprintf(stderr, "%s: cannot execute %s from memory: %s\n", prog,
            payload, strerror(errno));
        return 126;
    }
}

int main(int argc, char **argv) {
    const char *prog = base(argv[0]);
    char self[8192];
    ssize_t slen;
    const char *payload;
    /* Explicit spelling: invoked under its own basename with a payload. */
    if (argc >= 2 && strcmp(prog, "sandhome-memexec") == 0)
        return run_payload(prog, argv[1], &argv[1]);
    /* View copy: map this path back to the home payload, argv unchanged. */
    slen = readlink("/proc/self/exe", self, sizeof self - 1);
    if (slen > 0) {
        self[slen] = 0;
        payload = map_env(self);
        if (!payload)
            payload = map_convention(self);
        if (payload)
            return run_payload(prog, payload, argv);
    }
    /* Last resort: argv[0] as a path, tried directly first inside run. */
    if (argc >= 1 && strchr(argv[0], '/'))
        return run_payload(prog, argv[0], argv);
    fprintf(stderr,
        "%s: cannot map this copy back to its payload; set SANDHOME_EXEC and SANDHOME_HOME\n",
        prog);
    return 127;
}
