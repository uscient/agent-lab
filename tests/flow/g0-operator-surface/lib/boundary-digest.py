#!/usr/bin/env python3
"""Emit one stable digest of a selected-boundary subtree.

This is the generic no-effect canary for the G0 operator-surface suite.  It
answers exactly one question: did a command leave a boundary byte-for-byte and
metadata-for-metadata unchanged?  It deliberately knows nothing about home
receipts, installation envelopes, or onboarding semantics; that authority stays
with the existing verified onboarding oracle, which this suite reuses through
the public ``scripts/agent-lab`` boundary rather than reimplementing.

An absent root prints ``absent`` rather than failing, so "the boundary was never
created" and "the boundary is unchanged" are distinguishable observations
instead of two different errors.

Relative paths named on the command line are recorded as entries but never
descended into.  The suite uses this for the ``cache`` component, where pinned
tool provisioning writes as a matter of course and would otherwise mask real
durable drift behind unrelated churn.

Two instruments are available, and the suite calibrates both:

``--durable``
    Records content, type, mode, ownership, link count, device, inode, and size
    but not timestamps.  This answers "was every durable byte and mode
    preserved?", which is the right question for an idempotent republication
    that may legitimately re-apply an unchanged mode.

default
    Records timestamps as well, so even a no-op ``chmod`` or a rewrite-and-
    restore is visible.  This is the stricter instrument and is the right
    question for a command that claimed to have no effect at all.

``--paths``
    Prints one sorted ``relative|kind|mode`` line per entry instead of a
    digest.  A digest answers "did anything change?"; this answers "*what*
    changed?", so a command whose durable effect must be exactly the effect the
    existing verified path produces can be compared against that path's own
    observed delta instead of against a hand-written allow-list.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import sys

READ_CHUNK = 65_536


def content_digest(path: Path, size: int) -> str:
    """Hash one regular file through a no-follow descriptor."""

    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        chunks: list[bytes] = []
        remaining = size + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(READ_CHUNK, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
    finally:
        os.close(descriptor)
    return hashlib.sha256(b"".join(chunks)).hexdigest()


def classify(path: Path, metadata: os.stat_result) -> tuple[str, str]:
    mode = metadata.st_mode
    if stat.S_ISDIR(mode):
        return "directory", ""
    if stat.S_ISREG(mode):
        try:
            return "file", content_digest(path, metadata.st_size)
        except OSError:
            # An unreadable durable child is itself a stable observation.
            return "file", "unreadable"
    if stat.S_ISLNK(mode):
        try:
            return "symlink", os.readlink(path)
        except OSError:
            return "symlink", "unreadable"
    if stat.S_ISFIFO(mode):
        return "fifo", ""
    if stat.S_ISSOCK(mode):
        return "socket", ""
    if stat.S_ISBLK(mode) or stat.S_ISCHR(mode):
        return "device", ""
    return "other", ""


def visit(
    path: Path,
    relative: str,
    records: list[list[object]],
    opaque: frozenset[str],
    durable_only: bool,
) -> None:
    metadata = path.lstat()
    kind, content = classify(path, metadata)
    records.append(
        [
            relative,
            kind,
            stat.S_IMODE(metadata.st_mode),
            metadata.st_uid,
            metadata.st_gid,
            metadata.st_nlink,
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_size,
            0 if durable_only else metadata.st_mtime_ns,
            0 if durable_only else metadata.st_ctime_ns,
            content,
        ]
    )
    if kind != "directory" or relative in opaque:
        return
    try:
        children = sorted(path.iterdir(), key=lambda item: os.fsencode(item.name))
    except OSError:
        # A boundary that cannot be listed is recorded rather than skipped, so a
        # command that makes a subtree unlistable still changes the digest.
        records.append([relative, "unlistable", 0, 0, 0, 0, 0, 0, 0, 0, 0, ""])
        return
    for child in children:
        child_relative = child.name if relative == "." else f"{relative}/{child.name}"
        visit(child, child_relative, records, opaque, durable_only)


def main(argv: list[str]) -> int:
    arguments = argv[1:]
    durable_only = False
    path_listing = False
    if arguments[:1] == ["--durable"]:
        durable_only = True
        arguments = arguments[1:]
    elif arguments[:1] == ["--paths"]:
        path_listing = True
        arguments = arguments[1:]
    if not arguments:
        print(
            f"usage: {argv[0]} [--durable|--paths] PATH [OPAQUE_RELATIVE ...]",
            file=sys.stderr,
        )
        return 2
    root = Path(arguments[0])
    opaque = frozenset(arguments[1:])
    if not os.path.lexists(root):
        print("absent")
        return 0
    records: list[list[object]] = []
    try:
        visit(root, ".", records, opaque, durable_only)
    except OSError as error:
        print(f"boundary digest failed: {error}", file=sys.stderr)
        return 125
    if path_listing:
        # Path, kind, and mode only: the stable shape of a durable effect, with
        # the volatile parts (content, inode, timestamps) deliberately left out
        # so two boundaries that received the same effect compare equal.
        for line in sorted(f"{record[0]}|{record[1]}|{record[2]:04o}" for record in records):
            print(line)
        return 0
    encoded = json.dumps(records, ensure_ascii=True, separators=(",", ":")).encode("ascii")
    print("sha256:" + hashlib.sha256(encoded).hexdigest())
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
