#!/bin/sh
#
# .xinitrc — the X session of a new operator account (desktop profile).
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# startx(1) reads ~/.xinitrc when the account has no .xsession, and it
# reads ~/.xsession when it has one. Both files are shipped, so the session
# of a new account is the Xfce session whatever the way the X server was
# started. The xfce package installs /usr/local/bin/startxfce4, which starts
# the Xfce session (xfce4-session).
#
# /etc/skel is copied into the home directory of every new account, so
# every operator account of the desktop profile starts in Xfce.

exec /usr/local/bin/startxfce4
