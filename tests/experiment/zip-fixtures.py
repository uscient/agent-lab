#!/usr/bin/env python3
"""Generate deterministic harmless ZIP intake fixtures for the shell contract."""

from __future__ import annotations

from pathlib import Path
import stat
import struct
import sys
import warnings
import zipfile


LOCAL = b"PK\x03\x04"
CENTRAL = b"PK\x01\x02"
EOCD = b"PK\x05\x06"


def zip_bytes(
    entries: list[tuple[str, bytes, int, int, bytes, bytes]],
    *,
    archive_comment: bytes = b"",
) -> bytes:
    from io import BytesIO

    output = BytesIO()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        with zipfile.ZipFile(output, "w") as archive:
            archive.comment = archive_comment
            for name, data, method, mode, extra, comment in entries:
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = method
                info.create_system = 3
                info.external_attr = mode << 16
                info.extra = extra
                info.comment = comment
                archive.writestr(info, data)
    return output.getvalue()


def one(
    name: str,
    data: bytes,
    method: int = zipfile.ZIP_STORED,
    mode: int = stat.S_IFREG | 0o600,
    extra: bytes = b"",
    comment: bytes = b"",
    archive_comment: bytes = b"",
) -> bytes:
    return zip_bytes(
        [(name, data, method, mode, extra, comment)],
        archive_comment=archive_comment,
    )


def offsets(data: bytes) -> tuple[int, int, int]:
    local = data.find(LOCAL)
    central = data.rfind(CENTRAL)
    eocd = data.rfind(EOCD)
    if local != 0 or central < 0 or eocd < 0:
        raise ValueError("fixture has no canonical ZIP records")
    return local, central, eocd


def u16(data: bytearray, offset: int, value: int) -> None:
    struct.pack_into("<H", data, offset, value)


def u32(data: bytearray, offset: int, value: int) -> None:
    struct.pack_into("<I", data, offset, value)


def mutate(base: bytes, operation) -> bytes:
    data = bytearray(base)
    operation(data, *offsets(data))
    return bytes(data)


def replace_names(base: bytes, replacement: bytes, *, local: bool = True, central: bool = True) -> bytes:
    if len(replacement) != len(b"experiment.cue"):
        raise ValueError("replacement name must preserve record lengths")
    data = bytearray(base)
    local_offset, central_offset, _ = offsets(data)
    if local:
        data[local_offset + 30 : local_offset + 44] = replacement
    if central:
        data[central_offset + 46 : central_offset + 60] = replacement
    return bytes(data)


def main() -> int:
    if len(sys.argv) != 3:
        return 2
    source = Path(sys.argv[1]).read_bytes()
    root = Path(sys.argv[2])
    root.mkdir(parents=True, exist_ok=True)

    regular = stat.S_IFREG | 0o600
    stored = one("experiment.cue", source)
    deflated = one("experiment.cue", source, zipfile.ZIP_DEFLATED)
    fixtures: dict[str, bytes] = {
        "stored.zip": stored,
        "deflated.zip": deflated,
        "wrong-case.zip": one("Experiment.cue", source),
        "wrapper.zip": one("wrapper/experiment.cue", source),
        "dotdot.zip": one("../experiment.cue", source),
        "backslash.zip": one("folder\\experiment.cue", source),
        "absolute.zip": one("/experiment.cue", source),
        "drive.zip": one("C:/experiment.cue", source),
        "unc.zip": one("//host/share/experiment.cue", source),
        "nonascii.zip": one("experıment.cue", source),
        "extra-entry.zip": zip_bytes(
            [
                ("experiment.cue", source, zipfile.ZIP_STORED, regular, b"", b""),
                ("metadata", b"harmless", zipfile.ZIP_STORED, regular, b"", b""),
            ]
        ),
        "duplicate.zip": zip_bytes(
            [
                ("experiment.cue", source, zipfile.ZIP_STORED, regular, b"", b""),
                ("experiment.cue", source, zipfile.ZIP_STORED, regular, b"", b""),
            ]
        ),
        "directory-type.zip": one("experiment.cue", source, mode=stat.S_IFDIR | 0o700),
        "symlink-type.zip": one("experiment.cue", source, mode=stat.S_IFLNK | 0o777),
        "fifo-type.zip": one("experiment.cue", source, mode=stat.S_IFIFO | 0o600),
        "extra-field.zip": one("experiment.cue", source, extra=b"\xfe\xca\x00\x00"),
        "file-comment.zip": one("experiment.cue", source, comment=b"metadata"),
        "archive-comment.zip": one("experiment.cue", source, archive_comment=b"metadata"),
    }

    fixtures["nul-name.zip"] = replace_names(stored, b"experiment.cu\x00")
    fixtures["control-name.zip"] = replace_names(stored, b"experiment.cu\x01")
    fixtures["encrypted.zip"] = mutate(
        stored,
        lambda data, local, central, _eocd: (
            u16(data, local + 6, struct.unpack_from("<H", data, local + 6)[0] | 1),
            u16(data, central + 8, struct.unpack_from("<H", data, central + 8)[0] | 1),
        ),
    )
    fixtures["strong-encrypted.zip"] = mutate(
        stored,
        lambda data, local, central, _eocd: (
            u16(data, local + 6, struct.unpack_from("<H", data, local + 6)[0] | 64),
            u16(data, central + 8, struct.unpack_from("<H", data, central + 8)[0] | 64),
        ),
    )
    fixtures["unsupported-method.zip"] = mutate(
        stored,
        lambda data, local, central, _eocd: (
            u16(data, local + 8, 99),
            u16(data, central + 10, 99),
        ),
    )
    fixtures["zip64-version.zip"] = mutate(
        stored,
        lambda data, local, central, _eocd: (
            u16(data, local + 4, 45),
            u16(data, central + 6, 45),
        ),
    )
    fixtures["zip64-sentinel.zip"] = mutate(
        stored,
        lambda data, local, central, eocd: (
            u32(data, local + 18, 0xFFFFFFFF),
            u32(data, local + 22, 0xFFFFFFFF),
            u32(data, central + 20, 0xFFFFFFFF),
            u32(data, central + 24, 0xFFFFFFFF),
            u16(data, eocd + 8, 0xFFFF),
            u16(data, eocd + 10, 0xFFFF),
        ),
    )
    fixtures["multidisk.zip"] = mutate(
        stored,
        lambda data, _local, _central, eocd: (
            u16(data, eocd + 4, 1),
            u16(data, eocd + 6, 1),
        ),
    )
    fixtures["data-descriptor.zip"] = mutate(
        stored,
        lambda data, local, central, _eocd: (
            u16(data, local + 6, struct.unpack_from("<H", data, local + 6)[0] | 8),
            u16(data, central + 8, struct.unpack_from("<H", data, central + 8)[0] | 8),
        ),
    )
    fixtures["zero-count.zip"] = mutate(
        stored,
        lambda data, _local, _central, eocd: (
            u16(data, eocd + 8, 0),
            u16(data, eocd + 10, 0),
        ),
    )
    fixtures["central-signature.zip"] = mutate(
        stored,
        lambda data, _local, central, _eocd: data.__setitem__(
            slice(central, central + 4), b"BAD!"
        ),
    )
    fixtures["central-name-mismatch.zip"] = replace_names(
        stored, b"Experiment.cue", local=False
    )
    fixtures["central-flags-mismatch.zip"] = mutate(
        stored,
        lambda data, _local, central, _eocd: u16(data, central + 8, 0x800),
    )
    fixtures["bad-crc.zip"] = mutate(
        stored,
        lambda data, local, central, _eocd: (
            u32(data, local + 14, 0),
            u32(data, central + 16, 0),
        ),
    )
    fixtures["bad-length.zip"] = mutate(
        stored,
        lambda data, local, central, _eocd: (
            u32(data, local + 22, len(source) - 1),
            u32(data, central + 24, len(source) - 1),
        ),
    )
    central_offset = offsets(stored)[1]
    fixtures["missing-central.zip"] = stored[:central_offset]
    deflated_central = offsets(deflated)[1]
    fixtures["truncated-deflate.zip"] = deflated[: deflated_central - 1]
    fixtures["trailing.zip"] = stored + b"trailing ambiguity"

    big_source = source + b"\n//" + (b"x" * 270_000) + b"\n"
    limit_source = source + b"\n//" + (
        b"x" * (262_144 - len(source) - 4)
    ) + b"\n"
    if len(limit_source) != 262_144:
        raise AssertionError("exact source-limit fixture has the wrong size")
    (root / "expanded-limit.cue").write_bytes(limit_source)
    fixtures["expanded-limit.zip"] = one(
        "experiment.cue", limit_source, zipfile.ZIP_DEFLATED
    )
    fixtures["expanded-over.zip"] = one("experiment.cue", big_source)
    fixtures["deflate-bomb.zip"] = one(
        "experiment.cue", big_source, zipfile.ZIP_DEFLATED
    )
    declared_small = bytearray(fixtures["deflate-bomb.zip"])
    local_offset, central_offset, _ = offsets(declared_small)
    u32(declared_small, local_offset + 22, len(source))
    u32(declared_small, central_offset + 24, len(source))
    fixtures["declared-small-large.zip"] = bytes(declared_small)
    fixtures["archive-over.zip"] = stored + (
        b"x" * (1_048_577 - len(stored))
    )

    for name, data in fixtures.items():
        (root / name).write_bytes(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
