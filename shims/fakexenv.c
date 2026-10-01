/* fakexenv.c  -  answer X11 client probes where no X server exists.
 *
 * For cages with no DISPLAY, no Wayland socket and no listening socket to
 * put one on (bind is denied, so no in-cage Xvfb is possible). X11 clients
 * that only PROBE a display -- open it, ask the screen count, query an
 * extension -- die on the open before reaching any rendering decision. This
 * shim answers those probes with a plausible fixed geometry (one screen,
 * 1024x768, 24-bit) and a fixed extension base, so probe-then-degrade
 * clients proceed to their fallback instead of exiting.
 *
 * WHAT THIS IS NOT. It is not a display: no window can be created, mapped
 * or drawn, and any call beyond the probe set fails honestly. A test that
 * needs pixels still needs a real server elsewhere. The prototypes below
 * are the stable Xlib ABI (opaque Display*, int returns); no X headers are
 * needed to build this file, and that is deliberate -- a cage building a
 * display fake should not need the display's development packages.
 *
 * Answered: XOpenDisplay, XCloseDisplay, XDefaultScreen, XScreenCount,
 * XServerVendor, XVendorRelease, XQueryExtension.
 *
 * Build: gcc -shared -fPIC -O2 -o fakexenv.so fakexenv.c
 * Scope switch: SANDHOME_FAKEXENV=0 (also no/off/false) disables it.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Opaque handles: the ABI only moves pointers, never inspects them. */
typedef struct { int tag; } sh_x_display;

static sh_x_display sh_the_display = { 0x58444953 };

static int sh_off(const char *name) {
    const char *v = getenv(name);
    if (!v || !*v) return 0;
    if (!strcmp(v, "0") || !strcmp(v, "no") || !strcmp(v, "off") || !strcmp(v, "false"))
        return 1;
    return 0;
}

/* Display *XOpenDisplay(char *) -- a display that is always there. When the
 * host HAS a display the shim still answers first; that is the documented
 * scope (probe answering), and SANDHOME_FAKEXENV=0 restores the host. */
void *XOpenDisplay(const char *display_name) {
    void *(*real_open)(const char *) = NULL;
    (void)display_name;
    if (sh_off("SANDHOME_FAKEXENV")) {
        real_open = (void *(*)(const char *))dlsym(RTLD_NEXT, "XOpenDisplay");
        if (!real_open) return NULL;
        return real_open(display_name);
    }
    return &sh_the_display;
}

int XCloseDisplay(void *display) {
    int (*real_close)(void *) = NULL;
    if (display == &sh_the_display && !sh_off("SANDHOME_FAKEXENV"))
        return 0;
    real_close = (int (*)(void *))dlsym(RTLD_NEXT, "XCloseDisplay");
    if (!real_close) return 0;
    return real_close(display);
}

int XDefaultScreen(void *display) {
    (void)display;
    return 0;
}

int XScreenCount(void *display) {
    (void)display;
    return 1;
}

char *XServerVendor(void *display) {
    (void)display;
    return (char *)"sandhome-fake-xserver";
}

int XVendorRelease(void *display) {
    (void)display;
    return 1;
}

/* Bool XQueryExtension(Display*, char*, int*, int*, int*, int*) -- every
 * extension present at a fixed base, so extension-gated code proceeds. */
int XQueryExtension(void *display, const char *name, int *major_opcode,
                    int *first_event, int *first_error) {
    (void)display;
    (void)name;
    if (sh_off("SANDHOME_FAKEXENV")) {
        int (*real_q)(void *, const char *, int *, int *, int *) = NULL;
        real_q = (int (*)(void *, const char *, int *, int *, int *))dlsym(RTLD_NEXT, "XQueryExtension");
        if (!real_q) return 0;
        return real_q(display, name, major_opcode, first_event, first_error);
    }
    if (major_opcode) *major_opcode = 128;
    if (first_event) *first_event = 64;
    if (first_error) *first_error = 0;
    return 1;
}
