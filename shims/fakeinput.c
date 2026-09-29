/* fakeinput.c  -  answer input-device opens where no input exists.
 *
 * For cages with no /dev/input and no /dev/uinput (measured here: neither
 * exists). Gamepad/keyboard/mouse tests start by OPENING /dev/input/event*;
 * without one that open fails and the test dies before any synthetic event
 * source matters. This shim redirects opens (and stats) under /dev/input/
 * and /dev/uinput onto /dev/null, so initialisation proceeds to the reads
 * and ioctls it can actually attempt.
 *
 * WHAT THIS IS NOT. It is not an event source: reads return EOF and
 * EVIOCG* ioctls fail, because there are no events to report and no
 * hardware to query. A test that needs synthetic events still needs one.
 * The open succeeding is the scope, stated so a passing open is not read
 * as a working gamepad.
 *
 * Build: gcc -shared -fPIC -O2 -o fakeinput.so fakeinput.c
 * Scope switch: SANDHOME_FAKEINPUT=0 (also no/off/false) disables it.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>

static int sh_off(const char *name) {
    const char *v = getenv(name);
    if (!v || !*v) return 0;
    if (!strcmp(v, "0") || !strcmp(v, "no") || !strcmp(v, "off") || !strcmp(v, "false"))
        return 1;
    return 0;
}

static int sh_is_input_path(const char *p) {
    if (!p) return 0;
    if (!strncmp(p, "/dev/input/", 11)) return 1;
    if (!strcmp(p, "/dev/input")) return 1;
    if (!strcmp(p, "/dev/uinput")) return 1;
    return 0;
}

static const char *sh_null(void) { return "/dev/null"; }

static mode_t sh_open_mode(va_list ap, int flags) {
    if ((flags & O_CREAT) || ((flags & O_TMPFILE) == O_TMPFILE))
        return (mode_t)va_arg(ap, mode_t);
    return 0;
}

int open(const char *path, int flags, ...) {
    static int (*real_open)(const char *, int, ...) = NULL;
    va_list ap;
    mode_t mode = 0;
    const char *use = path;

    if (!real_open) real_open = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
    va_start(ap, flags);
    mode = sh_open_mode(ap, flags);
    va_end(ap);

    if (!sh_off("SANDHOME_FAKEINPUT") && sh_is_input_path(path))
        use = sh_null();
    if (!real_open) { errno = ENOSYS; return -1; }
    return real_open(use, flags, mode);
}

int open64(const char *path, int flags, ...) {
    static int (*real_open64)(const char *, int, ...) = NULL;
    va_list ap;
    mode_t mode = 0;
    const char *use = path;

    if (!real_open64) real_open64 = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open64");
    va_start(ap, flags);
    mode = sh_open_mode(ap, flags);
    va_end(ap);

    if (!sh_off("SANDHOME_FAKEINPUT") && sh_is_input_path(path))
        use = sh_null();
    if (!real_open64) { errno = ENOSYS; return -1; }
    return real_open64(use, flags, mode);
}

int openat(int dirfd, const char *path, int flags, ...) {
    static int (*real_openat)(int, const char *, int, ...) = NULL;
    va_list ap;
    mode_t mode = 0;

    if (!real_openat) real_openat = (int (*)(int, const char *, int, ...))dlsym(RTLD_NEXT, "openat");
    va_start(ap, flags);
    mode = sh_open_mode(ap, flags);
    va_end(ap);

    /* Absolute paths only: a relative openat resolves against dirfd, which
     * this shim cannot see. */
    if (!sh_off("SANDHOME_FAKEINPUT") && sh_is_input_path(path)) {
        if (!real_openat) { errno = ENOSYS; return -1; }
        return real_openat(AT_FDCWD, sh_null(), flags, mode);
    }
    if (!real_openat) { errno = ENOSYS; return -1; }
    return real_openat(dirfd, path, flags, mode);
}

int openat64(int dirfd, const char *path, int flags, ...) {
    static int (*real_openat64)(int, const char *, int, ...) = NULL;
    va_list ap;
    mode_t mode = 0;

    if (!real_openat64) real_openat64 = (int (*)(int, const char *, int, ...))dlsym(RTLD_NEXT, "openat64");
    va_start(ap, flags);
    mode = sh_open_mode(ap, flags);
    va_end(ap);

    if (!sh_off("SANDHOME_FAKEINPUT") && sh_is_input_path(path)) {
        if (!real_openat64) { errno = ENOSYS; return -1; }
        return real_openat64(AT_FDCWD, sh_null(), flags, mode);
    }
    if (!real_openat64) { errno = ENOSYS; return -1; }
    return real_openat64(dirfd, path, flags, mode);
}

static int sh_stat_null(const char *path, struct stat *buf,
                        int (*real_fn)(const char *, struct stat *)) {
    if (!sh_off("SANDHOME_FAKEINPUT") && sh_is_input_path(path))
        return real_fn ? real_fn(sh_null(), buf) : -1;
    return real_fn ? real_fn(path, buf) : -1;
}

int stat(const char *path, struct stat *buf) {
    static int (*real_stat)(const char *, struct stat *) = NULL;
    if (!real_stat) real_stat = (int (*)(const char *, struct stat *))dlsym(RTLD_NEXT, "stat");
    if (!real_stat) { errno = ENOSYS; return -1; }
    return sh_stat_null(path, buf, real_stat);
}

int lstat(const char *path, struct stat *buf) {
    static int (*real_lstat)(const char *, struct stat *) = NULL;
    if (!real_lstat) real_lstat = (int (*)(const char *, struct stat *))dlsym(RTLD_NEXT, "lstat");
    if (!real_lstat) { errno = ENOSYS; return -1; }
    return sh_stat_null(path, buf, real_lstat);
}
