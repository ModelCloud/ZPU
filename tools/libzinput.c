/* Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
 * SPDX-License-Identifier: Apache-2.0
 *
 * Shared C library for the Python zmouse/zkeyboard bindings.
 *
 * Builds into libzinput.so and is loaded with ctypes from tools/zinput.py.
 * It exposes a small stable ABI so Python apps can create and drive virtual
 * Linux input devices without speaking the uinput ioctl protocol directly.
 */

#include "zinput.h"

#include <string.h>
#include <unistd.h>

#ifdef __linux__
#include <sys/file.h>
#endif

#include <linux/input-event-codes.h>

#ifndef KEY_MAX
#define KEY_MAX 0x2ff
#endif

#define ZMOUSE_AXIS_MAX 65535

#if defined(__GNUC__) || defined(__clang__)
#define ZINPUT_API __attribute__((visibility("default")))
#else
#define ZINPUT_API
#endif

static const char *default_device(const char *device) {
    return device ? device : "/dev/uinput";
}

static int code_for_button(int n) {
    switch (n) {
        case 1: return BTN_LEFT;
        case 2: return BTN_RIGHT;
        case 3: return BTN_MIDDLE;
        case 4: return BTN_SIDE;
        case 5: return BTN_EXTRA;
        default: return -1;
    }
}

ZINPUT_API int zmouse_create(const char *device) {
    int fd = zinput_open(default_device(device));
    if (fd < 0) return -1;

    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0) goto fail;
    if (ioctl(fd, UI_SET_KEYBIT, BTN_LEFT) < 0) goto fail;
    if (ioctl(fd, UI_SET_KEYBIT, BTN_RIGHT) < 0) goto fail;
    if (ioctl(fd, UI_SET_KEYBIT, BTN_MIDDLE) < 0) goto fail;
    if (ioctl(fd, UI_SET_KEYBIT, BTN_SIDE) < 0) goto fail;
    if (ioctl(fd, UI_SET_KEYBIT, BTN_EXTRA) < 0) goto fail;

    if (ioctl(fd, UI_SET_EVBIT, EV_REL) < 0) goto fail;
    if (ioctl(fd, UI_SET_RELBIT, REL_X) < 0) goto fail;
    if (ioctl(fd, UI_SET_RELBIT, REL_Y) < 0) goto fail;
    if (ioctl(fd, UI_SET_RELBIT, REL_WHEEL) < 0) goto fail;
    if (ioctl(fd, UI_SET_RELBIT, REL_HWHEEL) < 0) goto fail;
    if (ioctl(fd, UI_SET_RELBIT, REL_DIAL) < 0) goto fail;

    if (ioctl(fd, UI_SET_EVBIT, EV_ABS) < 0) goto fail;
    if (ioctl(fd, UI_SET_ABSBIT, ABS_X) < 0) goto fail;
    if (ioctl(fd, UI_SET_ABSBIT, ABS_Y) < 0) goto fail;

    struct uinput_abs_setup abs;
    memset(&abs, 0, sizeof(abs));
    abs.code = ABS_X;
    abs.absinfo.minimum = 0;
    abs.absinfo.maximum = ZMOUSE_AXIS_MAX;
    if (ioctl(fd, UI_ABS_SETUP, &abs) < 0) goto fail;

    abs.code = ABS_Y;
    if (ioctl(fd, UI_ABS_SETUP, &abs) < 0) goto fail;

#ifdef INPUT_PROP_POINTER
    if (ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_POINTER) < 0) {
        /* optional */
    }
#endif

    if (zinput_setup_device(fd, "zmouse", 0x1234, 0x0001) < 0) goto fail;
    if (zinput_create(fd) < 0) goto fail;
    return fd;

fail:
    close(fd);
    return -1;
}

ZINPUT_API int zmouse_destroy(int fd) {
    return zinput_destroy(fd);
}

static void zinput_lock(int fd) {
#ifdef __linux__
    if (fd >= 0) flock(fd, LOCK_EX);
#else
    (void)fd;
#endif
}

static void zinput_unlock(int fd) {
#ifdef __linux__
    if (fd >= 0) flock(fd, LOCK_UN);
#else
    (void)fd;
#endif
}

ZINPUT_API int zmouse_move(int fd, int dx, int dy) {
    zinput_lock(fd);
    int r = -1;
    if (zinput_emit(fd, EV_REL, REL_X, dx) < 0) goto unlock;
    if (zinput_emit(fd, EV_REL, REL_Y, dy) < 0) goto unlock;
    r = zinput_sync(fd);
unlock:
    zinput_unlock(fd);
    return r;
}

ZINPUT_API int zmouse_move_abs(int fd, int x, int y) {
    if (x < 0) x = 0;
    if (x > ZMOUSE_AXIS_MAX) x = ZMOUSE_AXIS_MAX;
    if (y < 0) y = 0;
    if (y > ZMOUSE_AXIS_MAX) y = ZMOUSE_AXIS_MAX;
    zinput_lock(fd);
    int r = -1;
    if (zinput_emit(fd, EV_ABS, ABS_X, x) < 0) goto unlock;
    if (zinput_emit(fd, EV_ABS, ABS_Y, y) < 0) goto unlock;
    r = zinput_sync(fd);
unlock:
    zinput_unlock(fd);
    return r;
}

ZINPUT_API int zmouse_button(int fd, int button, int down) {
    int code = code_for_button(button);
    if (code < 0) return -1;
    zinput_lock(fd);
    int r = -1;
    if (zinput_emit(fd, EV_KEY, (unsigned short)code, down ? 1 : 0) < 0) goto unlock;
    r = zinput_sync(fd);
unlock:
    zinput_unlock(fd);
    return r;
}

ZINPUT_API int zmouse_wheel(int fd, int value) {
    zinput_lock(fd);
    int r = -1;
    if (zinput_emit(fd, EV_REL, REL_WHEEL, value) < 0) goto unlock;
    r = zinput_sync(fd);
unlock:
    zinput_unlock(fd);
    return r;
}

ZINPUT_API int zmouse_hwheel(int fd, int value) {
    zinput_lock(fd);
    int r = -1;
    if (zinput_emit(fd, EV_REL, REL_HWHEEL, value) < 0) goto unlock;
    r = zinput_sync(fd);
unlock:
    zinput_unlock(fd);
    return r;
}

ZINPUT_API int zkeyboard_create(const char *device) {
    int fd = zinput_open(default_device(device));
    if (fd < 0) return -1;

    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0) goto fail;

    for (int code = 0; code <= KEY_MAX; ++code) {
        if (ioctl(fd, UI_SET_KEYBIT, code) < 0) {
            goto fail;
        }
    }

    if (ioctl(fd, UI_SET_EVBIT, EV_REP) < 0) {
        /* repeat is optional */
    }

#ifdef INPUT_PROP_POINTER
    if (ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_POINTER) < 0) {
        /* optional */
    }
#endif

    if (zinput_setup_device(fd, "zkeyboard", 0x1234, 0x0002) < 0) goto fail;
    if (zinput_create(fd) < 0) goto fail;
    return fd;

fail:
    close(fd);
    return -1;
}

ZINPUT_API int zkeyboard_destroy(int fd) {
    return zinput_destroy(fd);
}

ZINPUT_API int zkeyboard_key(int fd, int code, int value) {
    if (code < 0 || code > KEY_MAX) return -1;
    if (value < 0 || value > 2) return -1;
    zinput_lock(fd);
    int r = -1;
    if (zinput_emit(fd, EV_KEY, (unsigned short)code, value) < 0) goto unlock;
    r = zinput_sync(fd);
unlock:
    zinput_unlock(fd);
    return r;
}
