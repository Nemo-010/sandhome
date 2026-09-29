/* antiptrace.c  -  make software that refuses to run under a tracer run anyway.
 *
 * For cages whose seccomp profile denies the ptrace syscall class (measured here:
 * even a bogus ptrace request answers EPERM, so the kernel never validates
 * arguments -- a filter, not YAMA/LSM). Two things break in that world, and this
 * shim answers both:
 *
 *   1. A program that self-checks with ptrace(PTRACE_TRACEME) reads the refusal
 *      as "I am being debugged" and exits. Anti-debug guards, some licensing
 *      checks and a few crash handlers do exactly this. SANDHOME_ANTIPTRACE_TRACEME
 *      (default on) makes TRACEME return success without a tracer existing.
 *
 *   2. A program that reads TracerPid from /proc/self/status and treats a non-zero
 *      value as "I am being debugged". It is already 0 here, so the interesting
 *      case is the opposite one: a wrapper that SET the variable expected a tracer
 *      and now does not get one. Zero the field either way so the answer is stable,
 *      and zero wchan the same way -- a stopped tracee leaks "ptrace_stop" there.
 *
 * WHAT THIS IS NOT. It does not make a ptrace-based tracer work: the syscall is
 * denied and no interposer can change that (strace's own experiments prove the
 * refusal is a filter, and a filter runs before libc). It also does not shield a
 * program from a real tracer: this is an interposer, so it is only reached by
 * DYNAMIC binaries (see the STOP in lib/shim.sh on statically linked ones).
 *
 * Build: gcc -shared -fPIC -O2 -o antiptrace.so antiptrace.c
 * Use:   SANDHOME_SHIMS=1 (env.sh loads every shims slash-star.so), or
 *        LD_PRELOAD=./antiptrace.so ./app
 *
 * SCOPING. Both behaviours are separately switchable because they carry different
 * risk: faking TRACEME can let a program past a deliberate guard, while zeroing
 * TracerPid only changes what a program believes about its own parent. Defaults
 * are on for both, matching the tracer's --anti-anti-debug=traceme,status,wchan.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ptrace.h>

/* sh_off VAR -> true when VAR is set to an off spelling. The same spellings the
 * shell side treats as off, so one answer everywhere. */
static int sh_off(const char *name) {
    const char *v = getenv(name);
    if (!v || !*v) return 0;
    if (!strcmp(v, "0") || !strcmp(v, "no") || !strcmp(v, "off") || !strcmp(v, "false"))
        return 1;
    return 0;
}

/* ptrace() itself. PTRACE_TRACEME is the self-check; every other request is
 * forwarded untouched so a program that really means to attach still gets the
 * host's honest answer (EPERM here) rather than a lie. */
long ptrace(enum __ptrace_request request, ...) {
    static long (*real_ptrace)(enum __ptrace_request, ...) = NULL;
    va_list ap;
    void *pid, *addr, *data;

    if (!real_ptrace) {
        real_ptrace = (long (*)(enum __ptrace_request, ...))dlsym(RTLD_NEXT, "ptrace");
        if (!real_ptrace) {
            /* No real ptrace to forward to at all; only the faked request below
             * can be honoured, and everything else is honestly unsupported. */
        }
    }

    va_start(ap, request);
    pid  = va_arg(ap, void *);
    addr = va_arg(ap, void *);
    data = va_arg(ap, void *);
    va_end(ap);

    if (request == PTRACE_TRACEME && !sh_off("SANDHOME_ANTIPTRACE_TRACEME"))
        return 0;

    if (!real_ptrace) { errno = ENOSYS; return -1; }
    return real_ptrace(request, pid, addr, data);
}

/* open/open64 are interposed so a read of /proc/self/status (or /proc/<pid>/status,
 * or wchan) can be answered with the report the tracer would have rewritten. The
 * file is read into memory, edited, and handed back through a memfd the caller
 * owns, so lseek/read/fstat all behave like a normal file. */
#include <fcntl.h>
#include <sys/stat.h>

static int sh_is_status_path(const char *p) {
    return p && strstr(p, "/status") != NULL;
}
static int sh_is_wchan_path(const char *p) {
    return p && strstr(p, "/wchan") != NULL;
}

/* Zero a "Field:\tVALUE\n" line in place, keeping the field name and the tab so
 * the byte layout a reader expects is unchanged. Returns 1 when the field was
 * present. */
static int sh_zero_field(char *buf, const char *field) {
    size_t flen = strlen(field);
    char *p = buf;
    while ((p = strstr(p, field)) != NULL) {
        /* Must sit at the start of a line to be that field and not a substring. */
        if (p == buf || p[-1] == '\n') {
            char *v = p + flen;
            if (*v == ':') {
                v++;
                while (*v == ' ' || *v == '\t') v++;
                char *end = strchr(v, '\n');
                if (!end) end = v + strlen(v);
                size_t n = (size_t)(end - v);
                if (n) memset(v, '0', n);
                return 1;
            }
        }
        p += flen;
    }
    return 0;
}

static int sh_maybe_fake_status(const char *path, int flags, int (*real_open)(const char *, int, ...)); /* fwd */

/* The edited copy is handed back through a memfd. The name is DELIBERATELY not
 * a path: memfd_create names an anonymous file, and readlink("/proc/self/fd/N")
 * on it reads "/memfd:sandhome-status (deleted)". That is honest -- the caller's
 * fd really is not the on-disk /proc file -- and it avoids the trap issue #83
 * records, where a view-copied tool reported its own launcher path as the thing
 * it had opened. A consumer that re-reads the fd gets the edited bytes either
 * way; one that inspects the path learns it is synthetic rather than being told
 * a path that would open the unedited file if used. */
static int sh_reopen_edited(char *content, ssize_t len) {
    int fd = syscall(319, "sandhome-status", 0); /* memfd_create */
    if (fd < 0) return -1;
    if (len > 0 && write(fd, content, (size_t)len) != len) { close(fd); return -1; }
    lseek(fd, 0, SEEK_SET);
    return fd;
}

static int sh_maybe_fake_status(const char *path, int flags, int (*real_open)(const char *, int, ...)) {
    /* Only when the caller is opening it for reading and nothing is being created. */
    if ((flags & O_ACCMODE) != O_RDONLY) return -1;
    if (sh_off("SANDHOME_ANTIPTRACE_STATUS") && sh_off("SANDHOME_ANTIPTRACE_WCHAN"))
        return -1;

    /* STOP: THE REAL open, NOT THIS FILE'S open(). Calling the interposed open()
     * here re-enters the interposer, which calls this function again, which calls
     * open() -- a measured SIGSEGV the instant `cat /proc/self/status` ran. The
     * caller passes its dlsym(RTLD_NEXT, "open") so the recursion cannot happen. */
    if (!real_open) return -1;
    int fd = real_open(path, flags);
    if (fd < 0) return -1;

    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0 || st.st_size > 1 << 20) {
        return fd; /* Not a small text file; hand back the real descriptor. */
    }
    char *buf = malloc((size_t)st.st_size + 1);
    if (!buf) return fd;
    ssize_t n = read(fd, buf, (size_t)st.st_size);
    if (n < 0) { free(buf); return fd; }
    buf[n] = '\0';

    int changed = 0;
    if (!sh_off("SANDHOME_ANTIPTRACE_STATUS")) {
        if (sh_zero_field(buf, "TracerPid")) changed = 1;
    }
    if (!sh_off("SANDHOME_ANTIPTRACE_WCHAN")) {
        if (sh_zero_field(buf, "wchan")) changed = 1;
    }
    if (!changed) { free(buf); return fd; }

    int nfd = sh_reopen_edited(buf, n);
    free(buf);
    if (nfd < 0) return fd;
    close(fd);
    return nfd;
}

/* open()'s third argument exists ONLY when O_CREAT or O_TMPFILE is set. Reading
 * it unconditionally with va_arg is undefined for every other call -- measured
 * here as a SIGSEGV the moment `cat /proc/self/status` opened it (the very case
 * this shim exists for), while a call that passed a mode happened to survive.
 * The flag test is the whole fix: pass a benign 0 when no mode was given. */
static mode_t sh_open_mode(va_list ap, int flags) {
    if ((flags & O_CREAT) || ((flags & O_TMPFILE) == O_TMPFILE))
        return (mode_t)va_arg(ap, mode_t);
    return 0;
}

int open(const char *path, int flags, ...) {
    static int (*real_open)(const char *, int, ...) = NULL;
    va_list ap;
    mode_t mode = 0;

    if (!real_open) real_open = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
    va_start(ap, flags);
    mode = sh_open_mode(ap, flags);
    va_end(ap);

    if (sh_is_status_path(path) || sh_is_wchan_path(path)) {
        int fd = sh_maybe_fake_status(path, flags, real_open);
        if (fd >= 0) return fd;
    }
    if (!real_open) { errno = ENOSYS; return -1; }
    return real_open(path, flags, mode);
}

int open64(const char *path, int flags, ...) {
    static int (*real_open64)(const char *, int, ...) = NULL;
    va_list ap;
    mode_t mode = 0;

    if (!real_open64) real_open64 = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open64");
    va_start(ap, flags);
    mode = sh_open_mode(ap, flags);
    va_end(ap);

    if (sh_is_status_path(path) || sh_is_wchan_path(path)) {
        int fd = sh_maybe_fake_status(path, flags, real_open64);
        if (fd >= 0) return fd;
    }
    if (!real_open64) { errno = ENOSYS; return -1; }
    return real_open64(path, flags, mode);
}
