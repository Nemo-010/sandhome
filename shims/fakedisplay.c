/* fakedisplay.c  -  answer Wayland client probes where no compositor exists.
 *
 * For cages with no WAYLAND_DISPLAY and no socket to put one on (bind is
 * denied, so no in-cage compositor is possible). Wayland clients that only
 * PROBE -- connect, get the registry -- die on the connect before reaching
 * any fallback. This shim answers those two probes with opaque handles, so
 * probe-then-degrade clients proceed instead of exiting.
 *
 * WHAT THIS IS NOT. It is not a compositor: dispatch, roundtrip and object
 * creation have nothing behind them, and any call beyond the probe set fails
 * honestly. The prototypes are the stable wayland-client ABI (opaque
 * pointers); no Wayland headers are needed to build this file, and that is
 * deliberate.
 *
 * Answered: wl_display_connect, wl_display_disconnect, wl_display_get_registry,
 * wl_display_get_fd (a /dev/null descriptor, good for polling nothing).
 *
 * Build: gcc -shared -fPIC -O2 -o fakedisplay.so fakedisplay.c
 * Scope switch: SANDHOME_FAKEDISPLAY=0 (also no/off/false) disables it.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

typedef struct { int tag; } sh_wl_display;
typedef struct { int tag; } sh_wl_registry;

static sh_wl_display sh_the_display = { 0x574C4450 };
static sh_wl_registry sh_the_registry = { 0x574C5247 };
static int sh_nullfd = -1;

static int sh_off(const char *name) {
    const char *v = getenv(name);
    if (!v || !*v) return 0;
    if (!strcmp(v, "0") || !strcmp(v, "no") || !strcmp(v, "off") || !strcmp(v, "false"))
        return 1;
    return 0;
}

void *wl_display_connect(const char *name) {
    void *(*real_connect)(const char *) = NULL;
    (void)name;
    if (sh_off("SANDHOME_FAKEDISPLAY")) {
        real_connect = (void *(*)(const char *))dlsym(RTLD_NEXT, "wl_display_connect");
        if (!real_connect) return NULL;
        return real_connect(name);
    }
    return &sh_the_display;
}

void wl_display_disconnect(void *display) {
    void (*real_disc)(void *) = NULL;
    if (display == &sh_the_display && !sh_off("SANDHOME_FAKEDISPLAY"))
        return;
    real_disc = (void (*)(void *))dlsym(RTLD_NEXT, "wl_display_disconnect");
    if (real_disc) real_disc(display);
}

void *wl_display_get_registry(void *display) {
    void *(*real_reg)(void *) = NULL;
    if (display == &sh_the_display && !sh_off("SANDHOME_FAKEDISPLAY"))
        return &sh_the_registry;
    real_reg = (void *(*)(void *))dlsym(RTLD_NEXT, "wl_display_get_registry");
    if (!real_reg) return NULL;
    return real_reg(display);
}

int wl_display_get_fd(void *display) {
    int (*real_fd)(void *) = NULL;
    if (display == &sh_the_display && !sh_off("SANDHOME_FAKEDISPLAY")) {
        if (sh_nullfd < 0)
            sh_nullfd = open("/dev/null", O_RDONLY);
        return sh_nullfd;
    }
    real_fd = (int (*)(void *))dlsym(RTLD_NEXT, "wl_display_get_fd");
    if (!real_fd) return -1;
    return real_fd(display);
}
