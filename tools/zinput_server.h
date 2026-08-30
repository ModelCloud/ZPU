/* Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
 * SPDX-License-Identifier: Apache-2.0
 *
 * Single-threaded, poll(2)-based Unix-socket server for zmouse/zkeyboard.
 *
 * It accepts many concurrent clients and processes one complete line at a time,
 * so the shared /dev/uinput fd is never written to by more than one logical
 * command at once.  This makes the drivers safe against multiple Python agents
 * or processes sending commands at the same time, without pulling in pthreads.
 */

#ifndef ZINPUT_SERVER_H
#define ZINPUT_SERVER_H

#include "zinput.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#ifndef ZINPUT_SERVER_MAX_CLIENTS
#define ZINPUT_SERVER_MAX_CLIENTS 64
#endif

#ifndef ZINPUT_SERVER_BUFSIZE
#define ZINPUT_SERVER_BUFSIZE 4096
#endif

struct zinput_client {
    int fd;
    char buf[ZINPUT_SERVER_BUFSIZE];
    size_t len;
};

typedef int (*zinput_command_fn)(const char *line, int uinput_fd);

static inline int zinput_server_set_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static inline int zinput_server_run(int listen_fd, int uinput_fd,
                                    zinput_command_fn process,
                                    volatile sig_atomic_t *running) {
    struct zinput_client clients[ZINPUT_SERVER_MAX_CLIENTS];
    struct pollfd fds[1 + ZINPUT_SERVER_MAX_CLIENTS];

    memset(clients, 0, sizeof(clients));

    if (zinput_server_set_nonblock(listen_fd) < 0) return -1;

    fds[0].fd = listen_fd;
    fds[0].events = POLLIN;
    int nfds = 1;

    while (*running) {
        int rc = poll(fds, (nfds_t)nfds, 100);
        if (rc < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (rc == 0) continue;

        if (fds[0].revents & POLLIN) {
            int c = accept(listen_fd, NULL, NULL);
            if (c >= 0) {
                if (nfds >= 1 + ZINPUT_SERVER_MAX_CLIENTS) {
                    close(c);
                } else if (zinput_server_set_nonblock(c) < 0) {
                    close(c);
                } else {
                    clients[nfds - 1].fd = c;
                    clients[nfds - 1].len = 0;
                    fds[nfds].fd = c;
                    fds[nfds].events = POLLIN;
                    nfds++;
                }
            }
        }

        for (int i = nfds - 1; i >= 1; --i) {
            int idx = i - 1;
            int revents = fds[i].revents;
            if (revents & (POLLERR | POLLHUP | POLLNVAL)) {
                close(clients[idx].fd);
                clients[idx] = clients[nfds - 2];
                fds[i] = fds[nfds - 1];
                nfds--;
                continue;
            }

            if (revents & POLLIN) {
                struct zinput_client *cl = &clients[idx];
                ssize_t n = recv(cl->fd, cl->buf + cl->len,
                                 sizeof(cl->buf) - cl->len - 1, 0);
                if (n <= 0) {
                    close(cl->fd);
                    clients[idx] = clients[nfds - 2];
                    fds[i] = fds[nfds - 1];
                    nfds--;
                    continue;
                }
                cl->len += (size_t)n;
                cl->buf[cl->len] = '\0';

                char *line_start = cl->buf;
                char *nl;
                while ((nl = strchr(line_start, '\n')) != NULL) {
                    *nl = '\0';
                    if (process(line_start, uinput_fd) == 0) {
                        *running = 0;
                        return 0;
                    }
                    line_start = nl + 1;
                }

                cl->len = strlen(line_start);
                if (cl->len > 0 && line_start != cl->buf) {
                    memmove(cl->buf, line_start, cl->len);
                }
            }
        }
    }

    return 1;
}

#endif
