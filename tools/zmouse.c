/* Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
 * SPDX-License-Identifier: Apache-2.0
 *
 * zmouse -- emulated mouse driver exposed to Linux through /dev/uinput.
 *
 * Creates a persistent virtual mouse device and listens on a Unix domain
 * socket for a simple line-based control protocol.  Intended for agentic
 * desktop workflows where a background process needs to drive the pointer
 * without a physical mouse.
 *
 * Control protocol (one command per line):
 *   m <dx> <dy>   relative move
 *   a <x> <y>     absolute move (0..65535 maps to axis min..max)
 *   b <n> <s>     button n (1=left,2=right,3=middle,4=side,5=extra) state s (0/1)
 *   w <n>         vertical wheel
 *   h <n>         horizontal wheel
 *   s             sync (auto-sync follows every command; explicit s is a no-op)
 *   # ...         comment
 *   q             quit the driver
 */

#include "zinput.h"
#include "zinput_server.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <linux/input-event-codes.h>

#define ZMOUSE_DEFAULT_DEVICE "/dev/uinput"
#define ZMOUSE_DEFAULT_SOCKET "/run/zmouse.sock"
#define ZMOUSE_VENDOR 0x1234
#define ZMOUSE_PRODUCT 0x0001
#define ZMOUSE_AXIS_MAX 65535

static volatile sig_atomic_t running = 1;

static void signal_handler(int sig) {
    (void)sig;
    running = 0;
}

static void usage(const char *prog) {
    fprintf(stderr,
        "usage: %s [options]\n"
        "  -d <path>   uinput device (default %s, or ZMOUSE_DEVICE env)\n"
        "  -s <path>   control socket (default %s, or ZMOUSE_SOCKET env)\n"
        "  -h          show this help\n",
        prog, ZMOUSE_DEFAULT_DEVICE, ZMOUSE_DEFAULT_SOCKET);
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

static int mouse_setup(int fd) {
    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0) return -1;
    if (ioctl(fd, UI_SET_KEYBIT, BTN_LEFT) < 0) return -1;
    if (ioctl(fd, UI_SET_KEYBIT, BTN_RIGHT) < 0) return -1;
    if (ioctl(fd, UI_SET_KEYBIT, BTN_MIDDLE) < 0) return -1;
    if (ioctl(fd, UI_SET_KEYBIT, BTN_SIDE) < 0) return -1;
    if (ioctl(fd, UI_SET_KEYBIT, BTN_EXTRA) < 0) return -1;

    if (ioctl(fd, UI_SET_EVBIT, EV_REL) < 0) return -1;
    if (ioctl(fd, UI_SET_RELBIT, REL_X) < 0) return -1;
    if (ioctl(fd, UI_SET_RELBIT, REL_Y) < 0) return -1;
    if (ioctl(fd, UI_SET_RELBIT, REL_WHEEL) < 0) return -1;
    if (ioctl(fd, UI_SET_RELBIT, REL_HWHEEL) < 0) return -1;
    if (ioctl(fd, UI_SET_RELBIT, REL_DIAL) < 0) return -1;

    if (ioctl(fd, UI_SET_EVBIT, EV_ABS) < 0) return -1;
    if (ioctl(fd, UI_SET_ABSBIT, ABS_X) < 0) return -1;
    if (ioctl(fd, UI_SET_ABSBIT, ABS_Y) < 0) return -1;

    struct uinput_abs_setup abs;
    memset(&abs, 0, sizeof(abs));
    abs.code = ABS_X;
    abs.absinfo.minimum = 0;
    abs.absinfo.maximum = ZMOUSE_AXIS_MAX;
    if (ioctl(fd, UI_ABS_SETUP, &abs) < 0) return -1;

    abs.code = ABS_Y;
    if (ioctl(fd, UI_ABS_SETUP, &abs) < 0) return -1;

#ifdef INPUT_PROP_POINTER
    if (ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_POINTER) < 0) {
        /* properties are optional; ignore failures */
    }
#endif

    if (zinput_setup_device(fd, "zmouse", ZMOUSE_VENDOR, ZMOUSE_PRODUCT) < 0) return -1;
    return zinput_create(fd);
}

static int process_command(const char *line, int fd) {
    char buf[512];
    if (strlen(line) >= sizeof(buf)) return 1;
    strncpy(buf, line, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';

    char *saveptr = NULL;
    char *tok = strtok_r(buf, " \t\r\n", &saveptr);
    if (!tok || tok[0] == '#') return 1;

    if (strcmp(tok, "q") == 0) return 0;

    if (strcmp(tok, "m") == 0) {
        char *x_tok = strtok_r(NULL, " \t\r\n", &saveptr);
        char *y_tok = strtok_r(NULL, " \t\r\n", &saveptr);
        if (!x_tok || !y_tok) return 1;
        int dx = (int)strtol(x_tok, NULL, 10);
        int dy = (int)strtol(y_tok, NULL, 10);
        zinput_emit(fd, EV_REL, REL_X, dx);
        zinput_emit(fd, EV_REL, REL_Y, dy);
        zinput_sync(fd);
    } else if (strcmp(tok, "a") == 0) {
        char *x_tok = strtok_r(NULL, " \t\r\n", &saveptr);
        char *y_tok = strtok_r(NULL, " \t\r\n", &saveptr);
        if (!x_tok || !y_tok) return 1;
        int x = (int)strtol(x_tok, NULL, 10);
        int y = (int)strtol(y_tok, NULL, 10);
        if (x < 0) x = 0;
        if (x > ZMOUSE_AXIS_MAX) x = ZMOUSE_AXIS_MAX;
        if (y < 0) y = 0;
        if (y > ZMOUSE_AXIS_MAX) y = ZMOUSE_AXIS_MAX;
        zinput_emit(fd, EV_ABS, ABS_X, x);
        zinput_emit(fd, EV_ABS, ABS_Y, y);
        zinput_sync(fd);
    } else if (strcmp(tok, "b") == 0) {
        char *n_tok = strtok_r(NULL, " \t\r\n", &saveptr);
        char *s_tok = strtok_r(NULL, " \t\r\n", &saveptr);
        if (!n_tok || !s_tok) return 1;
        int n = (int)strtol(n_tok, NULL, 10);
        int s = (int)strtol(s_tok, NULL, 10);
        int code = code_for_button(n);
        if (code < 0) return 1;
        zinput_emit(fd, EV_KEY, (unsigned short)code, s ? 1 : 0);
        zinput_sync(fd);
    } else if (strcmp(tok, "w") == 0) {
        char *n_tok = strtok_r(NULL, " \t\r\n", &saveptr);
        if (!n_tok) return 1;
        int n = (int)strtol(n_tok, NULL, 10);
        zinput_emit(fd, EV_REL, REL_WHEEL, n);
        zinput_sync(fd);
    } else if (strcmp(tok, "h") == 0) {
        char *n_tok = strtok_r(NULL, " \t\r\n", &saveptr);
        if (!n_tok) return 1;
        int n = (int)strtol(n_tok, NULL, 10);
        zinput_emit(fd, EV_REL, REL_HWHEEL, n);
        zinput_sync(fd);
    } else if (strcmp(tok, "s") == 0) {
        zinput_sync(fd);
    } else {
        fprintf(stderr, "zmouse: unknown command '%s'\n", tok);
    }
    return 1;
}

int main(int argc, char **argv) {
    const char *device = getenv("ZMOUSE_DEVICE");
    if (!device) device = ZMOUSE_DEFAULT_DEVICE;
    const char *socket_path = getenv("ZMOUSE_SOCKET");
    if (!socket_path) socket_path = ZMOUSE_DEFAULT_SOCKET;

    int opt;
    while ((opt = getopt(argc, argv, "hd:s:")) != -1) {
        switch (opt) {
            case 'd': device = optarg; break;
            case 's': socket_path = optarg; break;
            case 'h': usage(argv[0]); return 0;
            default: usage(argv[0]); return 2;
        }
    }
    if (optind != argc) {
        usage(argv[0]);
        return 2;
    }

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    int fd = zinput_open(device);
    if (fd < 0) {
        fprintf(stderr, "zmouse: cannot open %s: %s\n", device, strerror(errno));
        return 1;
    }

    if (mouse_setup(fd) < 0) {
        fprintf(stderr, "zmouse: cannot configure uinput device: %s\n", strerror(errno));
        close(fd);
        return 1;
    }

    int sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock < 0) {
        fprintf(stderr, "zmouse: cannot create socket: %s\n", strerror(errno));
        zinput_destroy(fd);
        return 1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);
    unlink(socket_path);

    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "zmouse: cannot bind %s: %s\n", socket_path, strerror(errno));
        close(sock);
        zinput_destroy(fd);
        return 1;
    }

    if (listen(sock, 16) < 0) {
        fprintf(stderr, "zmouse: cannot listen: %s\n", strerror(errno));
        close(sock);
        zinput_destroy(fd);
        return 1;
    }

    zinput_server_run(sock, fd, process_command, &running);

    close(sock);
    zinput_destroy(fd);
    unlink(socket_path);
    return 0;
}
