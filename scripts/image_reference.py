#!/usr/bin/env python3
"""Shared pure grammar for Experiment image names and immutable OCI subjects."""

from __future__ import annotations

import re


IMAGE_COMPONENT = re.compile(r"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$")
OCI_SUBJECT = re.compile(
    r"^([a-z0-9]+([.-][a-z0-9]+)*"
    r"(:(?:[1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|"
    r"65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5]))?/)?"
    r"[a-z0-9]+([._-][a-z0-9]+)*"
    r"(/[a-z0-9]+([._-][a-z0-9]+)*)*"
    r"@sha256:[0-9a-f]{64}$"
)


def valid_image_name(value: object) -> bool:
    if not isinstance(value, str) or not value.isascii():
        return False
    encoded = value.encode("ascii")
    parts = value.split(".")
    return (
        len(encoded) <= 63
        and len(parts) == 2
        and all(1 <= len(part.encode("ascii")) <= 31 for part in parts)
        and all(IMAGE_COMPONENT.fullmatch(part) is not None for part in parts)
    )


def valid_oci_subject(value: object) -> bool:
    return (
        isinstance(value, str)
        and value.isascii()
        and 1 <= len(value.encode("ascii")) <= 255
        and OCI_SUBJECT.fullmatch(value) is not None
    )
