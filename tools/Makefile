# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0

CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra -Werror
LDFLAGS ?=

ZINPUT_BINARIES = zmouse zkeyboard
ZINPUT_LIBRARIES = libzinput.so

.PHONY: all clean

all: $(ZINPUT_BINARIES) $(ZINPUT_LIBRARIES)

zmouse: zmouse.c zinput.h
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ $< $(LDFLAGS)

zkeyboard: zkeyboard.c zinput.h
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ $< $(LDFLAGS)

libzinput.so: libzinput.c zinput.h
	$(CC) $(CFLAGS) -fPIC -shared $(CPPFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(ZINPUT_BINARIES) $(ZINPUT_LIBRARIES)
