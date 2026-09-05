#!/bin/sh
# phaneslight-template v3.8.1 anchor-check
# POSIX launcher for the anchor-check node program. The program is ONE artifact shared by both
# platforms, exactly as scripts/cli.js already is, so this file is a launcher and carries no
# node-core region of its own: there is no second copy here to drift.
#
# This is NOT one of the seven Node-bearing ports. Those carry their program in their own tail and
# read it back with sed, because a dash heredoc silently delivers a body of 4096 bytes or more as
# zero bytes. Here the program is a real file on disk, so node opens it directly and the heredoc
# hazard never arises.
#
# The program resolves as a SIBLING of this launcher, which is true after install-templates
# flattens the library into .phaneslight/scripts/ and false in the plugin source tree where this
# file sits one directory below the program. A control that checks the program must invoke node
# against templates/scripts/anchor-check.js directly and never through this launcher.
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd); export PHANESLIGHT_HERE="$here"
command -v node >/dev/null 2>&1 || { echo "anchor-check: node is required on PATH and was not found" >&2; exit 1; }
program="$here/anchor-check.js"
[ -f "$program" ] || { echo "anchor-check: the node program is not beside this launcher ($program)" >&2; exit 1; }
exec node "$program" "$@"
