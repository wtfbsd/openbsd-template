#!/bin/sh
#
# .xsession — the X session of a new operator account (desktop profile).
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The classic X session file: a session started with startx (xenodm(1))
# runs it. The xfce package installs /usr/local/bin/startxfce4, which
# starts the Xfce session (xfce4-session).
#
# /etc/skel is copied into the home directory of every new account, so
# every operator account of the desktop profile starts in Xfce.

exec /usr/local/bin/startxfce4
