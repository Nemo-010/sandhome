/* fakedrm.c  -  answer GPU enumeration opens where no GPU exists.
 *
 * For cages with no /dev/dri and no /sys/class/drm (measured here: neither
 * path exists). GL/Vulkan/VA-API/KMS clients start by OPENING the device;
 * without one that open fails and the whole enumeration dies before any
 * null-driver lever matters. This shim redirects opens (and stats) under
 * /dev/dri/ and /sys/class/drm/ onto /dev/null, so enumeration proceeds to
 * the capability checks it can actually answer.
 *
 * WHAT THIS IS NOT. It does not make rendering correct or even possible:
 * ioctls against the redirected descriptor fail (ENOTTY from /dev/null),
 * so version and capability queries still fail. It makes initialisation
 * stop failing at the open, which is what a hardware smoke test needs, and
 * each redirected open is the only lie told. Where mesa's swrast/llvmpipe
 * is present, LIBGL_ALWAYS_SOFTWARE=1 is the better answer because it
 * produces real pixels; see docs/guide.md.
 *
 * Build: gcc -shared -fPIC -O2 -o fakedrm.so fakedrm.c
 * Scope switch: SANDHOME_FAKEDRM=0 (also no/off/false) disables it.
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

static int sh_is_drm_path(const char *p) {
    if (!p) return 0;
    if (!strncmp(p, "/dev/dri/", 9)) return 1;
    if (!strcmp(p, "/dev/dri")) return 1;
    if (!strncmp(p, "/sys/class/drm/", 15)) return 1;
    if (!strcmp(p, "/sys/class/drm")) return 1;
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

    if (!sh_off("SANDHOME_FAKEDRM") && sh_is_drm_path(path))
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

    if (!sh_off("SANDHOME_FAKEDRM") && sh_is_drm_path(path))
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

    /* Only absolute DRM paths redirect: a relative openat is resolved
     * against dirfd, which this shim cannot see, so guessing would
     * redirect the wrong files. Absolute paths are unambiguous. */
    if (!sh_off("SANDHOME_FAKEDRM") && sh_is_drm_path(path)) {
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

    if (!sh_off("SANDHOME_FAKEDRM") && sh_is_drm_path(path)) {
        if (!real_openat64) { errno = ENOSYS; return -1; }
        return real_openat64(AT_FDCWD, sh_null(), flags, mode);
    }
    if (!real_openat64) { errno = ENOSYS; return -1; }
    return real_openat64(dirfd, path, flags, mode);
}

/* stat/lstat answer the /dev/null identity for DRM paths, so existence and
 * type checks (S_ISCHR) pass the way the redirected open does. */
static int sh_stat_null(const char *path, struct stat *buf,
                        int (*real_fn)(const char *, struct stat *)) {
    if (!sh_off("SANDHOME_FAKEDRM") && sh_is_drm_path(path))
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
