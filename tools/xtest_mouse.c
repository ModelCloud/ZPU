/* Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
 * SPDX-License-Identifier: Apache-2.0
 *
 * Simulate a pointer device using the X11 XTEST extension.  The program opens
 * the requested display, queries the root screen size, and then drives the
 * pointer across the screen in a smooth pattern from a background thread of
 * execution.  It is intended to be launched inside a SmolVM guest while a
 * Vulkan desktop workload (vkcube) is rendering through ZPU on the shared
 * host X display.
 */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <X11/Xlib.h>
#include <X11/extensions/XTest.h>

static void usage(const char *prog) {
    fprintf(stderr,
        "usage: %s [options]\n"
        "  -display <name>    X display (default :0)\n"
        "  -duration <sec>    motion duration in seconds (default 10)\n"
        "  -hz <n>            update frequency (default 60)\n"
        "  -path <perimeter|figure8>  motion path (default perimeter)\n",
        prog);
}

static void perimeter_path(double t, int w, int h, int *out_x, int *out_y) {
    /* Trace the screen perimeter: start top-right, move left across the top,
       down the left edge, right across the bottom, and up the right edge. */
    int x = 0, y = 0;
    if (t < 0.25) {
        const double u = t / 0.25;
        x = (int)((w - 1) * (1.0 - u));
        y = 0;
    } else if (t < 0.50) {
        const double u = (t - 0.25) / 0.25;
        x = 0;
        y = (int)((h - 1) * u);
    } else if (t < 0.75) {
        const double u = (t - 0.50) / 0.25;
        x = (int)((w - 1) * u);
        y = h - 1;
    } else {
        const double u = (t - 0.75) / 0.25;
        x = w - 1;
        y = (int)((h - 1) * (1.0 - u));
    }
    *out_x = x;
    *out_y = y;
}

static void figure8_path(double t, int w, int h, int *out_x, int *out_y) {
    /* Lissajous figure-8 that covers the whole screen. */
    const double theta = t * 2.0 * 3.14159265358979323846 * 2.0;
    const double sx = 0.5 + 0.5 * sin(theta);
    const double sy = 0.5 + 0.5 * sin(2.0 * theta);
    *out_x = (int)(sx * (w - 1));
    *out_y = (int)(sy * (h - 1));
}

int main(int argc, char **argv) {
    const char *display_name = ":0";
    int duration = 10;
    int hz = 60;
    const char *path_name = "perimeter";

    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "-display") == 0 && i + 1 < argc) {
            display_name = argv[++i];
        } else if (strcmp(argv[i], "-duration") == 0 && i + 1 < argc) {
            duration = atoi(argv[++i]);
            if (duration < 1) duration = 1;
        } else if (strcmp(argv[i], "-hz") == 0 && i + 1 < argc) {
            hz = atoi(argv[++i]);
            if (hz < 1) hz = 1;
            if (hz > 1000) hz = 1000;
        } else if (strcmp(argv[i], "-path") == 0 && i + 1 < argc) {
            path_name = argv[++i];
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            usage(argv[0]);
            return 0;
        } else {
            usage(argv[0]);
            return 2;
        }
    }

    Display *dpy = XOpenDisplay(display_name);
    if (!dpy) {
        fprintf(stderr, "xtest_mouse: cannot open display %s\n", display_name);
        return 1;
    }

    int screen = DefaultScreen(dpy);
    int w = DisplayWidth(dpy, screen);
    int h = DisplayHeight(dpy, screen);
    if (w <= 0 || h <= 0) {
        fprintf(stderr, "xtest_mouse: invalid screen dimensions %dx%d\n", w, h);
        XCloseDisplay(dpy);
        return 1;
    }

    int event_base, error_base, major_version, minor_version;
    if (!XTestQueryExtension(dpy, &event_base, &error_base, &major_version, &minor_version)) {
        fprintf(stderr, "xtest_mouse: XTest extension not available\n");
        XCloseDisplay(dpy);
        return 1;
    }

    void (*path_fn)(double, int, int, int *, int *) = perimeter_path;
    if (strcmp(path_name, "figure8") == 0) {
        path_fn = figure8_path;
    } else if (strcmp(path_name, "perimeter") != 0) {
        fprintf(stderr, "xtest_mouse: unknown path %s, using perimeter\n", path_name);
    }

    const int total = duration * hz;
    const useconds_t interval_us = 1000000 / hz;

    for (int i = 0; i <= total; ++i) {
        const double t = (double)i / (double)total;
        int x, y;
        path_fn(t, w, h, &x, &y);
        XTestFakeMotionEvent(dpy, screen, x, y, CurrentTime);
        XFlush(dpy);
        if (i < total) {
            usleep(interval_us);
        }
    }

    XCloseDisplay(dpy);
    return 0;
}
