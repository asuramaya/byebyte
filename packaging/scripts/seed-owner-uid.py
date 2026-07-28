#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Shared by install.sh and the .deb's postinst: stamp owner_uid into a
config.json. Reads src, sets owner_uid, writes dst (src == dst for an
in-place stamp, which is what postinst does on a freshly unpacked
conffile). Callers decide "is this actually a fresh install?" themselves
— this script never checks, it just performs the one shared mutation, so
the two installers can't drift on what "seeding" means.
"""
import json
import sys

src, dst, uid = sys.argv[1], sys.argv[2], int(sys.argv[3])
cfg = json.load(open(src))
cfg["owner_uid"] = uid
with open(dst, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
