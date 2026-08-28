/* Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
 * SPDX-License-Identifier: Apache-2.0
 *
 * zkeyboard -- emulated keyboard driver exposed to Linux through /dev/uinput.
 *
 * Creates a persistent virtual keyboard device and listens on a Unix domain
 * socket for a simple line-based control protocol.  Intended for agentic
 * desktop workflows where a background process needs to inject keystrokes
 * without a physical keyboard.
 *
 * Control protocol (one command per line):
 *   k <keycode> <value>   key event (value 0=up, 1=down, 2=repeat)
 *   s                     sync (auto-sync follows every command)
 *   # ...                 comment
 *   q                     quit the driver
 */

#include "zinput.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <linux/input-event-codes.h>

#ifndef KEY_MAX
#define KEY_MAX 0x2ff
#endif

#define ZKEYBOARD_DEFAULT_DEVICE "/dev/uinput"
#define ZKEYBOARD_DEFAULT_SOCKET "/run/zkeyboard.sock"
#define ZKEYBOARD_VENDOR 0x1234
#define ZKEYBOARD_PRODUCT 0x0002

static volatile sig_atomic_t running = 1;

static void signal_handler(int sig) {
    (void)sig;
    running = 0;
}

static void usage(const char *prog) {
    fprintf(stderr,
        "usage: %s [options]\n"
        "  -d <path>   uinput device (default %s, or ZKEYBOARD_DEVICE env)\n"
        "  -s <path>   control socket (default %s, or ZKEYBOARD_SOCKET env)\n"
        "  -h          show this help\n",
        prog, ZKEYBOARD_DEFAULT_DEVICE, ZKEYBOARD_DEFAULT_SOCKET);
}

static int keyboard_setup(int fd) {
    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0) return -1;

    for (int code = 0; code <= KEY_MAX; ++code) {
        if (ioctl(fd, UI_SET_KEYBIT, code) < 0) {
            return -1;
        }
    }

    if (ioctl(fd, UI_SET_EVBIT, EV_REP) < 0) {
        /* repeat is optional; ignore failures */
    }

#ifdef INPUT_PROP_POINTER
    if (ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_POINTER) < 0) {
        /* properties are optional; ignore failures */
    }
#endif

    if (zinput_setup_device(fd, "zkeyboard", ZKEYBOARD_VENDOR, ZKEYBOARD_PRODUCT) < 0) return -1;
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

    if (strcmp(tok, "k") == 0) {
        char *code_tok = strtok_r(NULL, " \t\r\n", &saveptr);
        char *value_tok = strtok_r(NULL, " \t\r\n", &saveptr);
        if (!code_tok || !value_tok) return 1;
        int code = (int)strtol(code_tok, NULL, 10);
        int value = (int)strtol(value_tok, NULL, 10);
        if (code < 0 || code > KEY_MAX) return 1;
        if (value < 0 || value > 2) return 1;
        zinput_emit(fd, EV_KEY, (unsigned short)code, value);
        zinput_sync(fd);
    } else if (strcmp(tok, "s") == 0) {
        zinput_sync(fd);
    } else {
        fprintf(stderr, "zkeyboard: unknown command '%s'\n", tok);
    }
    return 1;
}

static int handle_client(int cfd, int uinput_fd) {
    char buf[4096];
    size_t len = 0;
    while (running) {
        ssize_t n = recv(cfd, buf + len, sizeof(buf) - len - 1, 0);
        if (n <= 0) break;
        len += (size_t)n;
        buf[len] = '\0';

        char *line_start = buf;
        char *nl;
        while ((nl = strchr(line_start, '\n')) != NULL) {
            *nl = '\0';
            if (process_command(line_start, uinput_fd) == 0) {
                running = 0;
                return 0;
            }
            line_start = nl + 1;
        }

        len = strlen(line_start);
        if (len > 0 && line_start != buf) {
            memmove(buf, line_start, len);
        }
    }
    return 1;
}

int main(int argc, char **argv) {
    const char *device = getenv("ZKEYBOARD_DEVICE");
    if (!device) device = ZKEYBOARD_DEFAULT_DEVICE;
    const char *socket_path = getenv("ZKEYBOARD_SOCKET");
    if (!socket_path) socket_path = ZKEYBOARD_DEFAULT_SOCKET;

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
        fprintf(stderr, "zkeyboard: cannot open %s: %s\n", device, strerror(errno));
        return 1;
    }

    if (keyboard_setup(fd) < 0) {
        fprintf(stderr, "zkeyboard: cannot configure uinput device: %s\n", strerror(errno));
        close(fd);
        return 1;
    }

    int sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock < 0) {
        fprintf(stderr, "zkeyboard: cannot create socket: %s\n", strerror(errno));
        zinput_destroy(fd);
        return 1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);
    unlink(socket_path);

    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "zkeyboard: cannot bind %s: %s\n", socket_path, strerror(errno));
        close(sock);
        zinput_destroy(fd);
        return 1;
    }

    if (listen(sock, 4) < 0) {
        fprintf(stderr, "zkeyboard: cannot listen: %s\n", strerror(errno));
        close(sock);
        zinput_destroy(fd);
        return 1;
    }

    while (running) {
        int c = accept(sock, NULL, NULL);
        if (c < 0) {
            if (errno == EINTR) continue;
            break;
        }
        handle_client(c, fd);
        close(c);
    }

    close(sock);
    zinput_destroy(fd);
    unlink(socket_path);
    return 0;
}
