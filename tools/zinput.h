/* Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
 * SPDX-License-Identifier: Apache-2.0
 *
 * Small helpers for creating virtual Linux input devices through /dev/uinput.
 */

#ifndef ZINPUT_H
#define ZINPUT_H

#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/uinput.h>
#include <linux/input.h>

static inline int zinput_open(const char *path) {
    int fd = open(path, O_RDWR | O_NONBLOCK);
    if (fd < 0) {
        fd = open(path, O_WRONLY | O_NONBLOCK);
    }
    return fd;
}

static inline int zinput_setup_device(int fd, const char *name, __u16 vendor, __u16 product) {
    if (ioctl(fd, UI_SET_EVBIT, EV_SYN) < 0) {
        return -1;
    }

    struct uinput_setup usetup;
    memset(&usetup, 0, sizeof(usetup));
    usetup.id.bustype = BUS_USB;
    usetup.id.vendor = vendor;
    usetup.id.product = product;
    usetup.id.version = 1;
    strncpy((char *)usetup.name, name, UINPUT_MAX_NAME_SIZE - 1);
    usetup.name[UINPUT_MAX_NAME_SIZE - 1] = '\0';

    if (ioctl(fd, UI_DEV_SETUP, &usetup) < 0) {
        return -1;
    }
    return 0;
}

static inline int zinput_create(int fd) {
    return ioctl(fd, UI_DEV_CREATE, 0);
}

static inline int zinput_destroy(int fd) {
    ioctl(fd, UI_DEV_DESTROY, 0);
    return close(fd);
}

static inline int zinput_emit(int fd, __u16 type, __u16 code, __s32 value) {
    struct input_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = type;
    ev.code = code;
    ev.value = value;
    return (int)write(fd, &ev, sizeof(ev));
}

static inline int zinput_sync(int fd) {
    return zinput_emit(fd, EV_SYN, SYN_REPORT, 0);
}

#endif
