# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0

CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra -Werror
LDFLAGS ?=

ZINPUT_BINARIES = zmouse zkeyboard

.PHONY: all clean

all: $(ZINPUT_BINARIES)

zmouse: zmouse.c zinput.h
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ $< $(LDFLAGS)

zkeyboard: zkeyboard.c zinput.h
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(ZINPUT_BINARIES)
