"""Describe the byte-level compatibility rules for the Ursa 4.9 boot family."""

import re
import struct
import zlib

from common import dtbs, sha


# These are metadata fields in the pinned arm64 Image, not a fuzzy hash of code.
HOST_FIELDS = (20447294, 20447558)
TIME_FIELDS = (20447508, 35263886)
BUILD_ID_OFFSET = 30198208
BUILD_FIELDS = (*((offset, 12) for offset in HOST_FIELDS),
                *((offset, 28) for offset in TIME_FIELDS), (BUILD_ID_OFFSET, 8))
INITRAMFS_OFFSET = 31502912
INITRAMFS_LIMIT = 136
INITRAMFS_SIZE_FIELD = INITRAMFS_OFFSET + INITRAMFS_LIMIT
INITRAMFS_END_POINTER = 23933536
NEWC_MTIMES = (46, 162, 286)


def stock_identity(plain):
    host, host_copy = (plain[offset:offset + 12] for offset in HOST_FIELDS)
    timestamp, timestamp_copy = (plain[offset:offset + 28] for offset in TIME_FIELDS)
    if (not re.fullmatch(rb"[0-9a-f]{12}", host) or host != host_copy
            or not re.fullmatch(rb"[A-Z][a-z]{2} [A-Z][a-z]{2} [ 0-9][0-9] [0-9:]{8} UTC [0-9]{4}", timestamp)
            or timestamp != timestamp_copy):
        raise ValueError("Unexpected kernel build metadata")
    end = struct.unpack_from("<I", plain, INITRAMFS_END_POINTER)[0]
    length = end - INITRAMFS_OFFSET
    if not 1 <= length <= INITRAMFS_LIMIT or struct.unpack_from("<I", plain, INITRAMFS_SIZE_FIELD)[0] != length:
        raise ValueError("Unexpected built-in initramfs length")
    decoder = zlib.decompressobj(31)
    cpio = bytearray(decoder.decompress(plain[INITRAMFS_OFFSET:end], 513))
    if not decoder.eof or decoder.unused_data or len(cpio) != 512:
        raise ValueError("Unexpected built-in initramfs stream")
    for offset in NEWC_MTIMES:
        if not re.fullmatch(rb"[0-9A-Fa-f]{8}", cpio[offset:offset + 8]):
            raise ValueError("Unexpected built-in initramfs timestamp")
        cpio[offset:offset + 8] = bytes(8)
    if any(plain[end:INITRAMFS_OFFSET + INITRAMFS_LIMIT]):
        raise ValueError("Unexpected data following the built-in initramfs")
    masked = bytearray(plain)
    for offset, size in (*BUILD_FIELDS, (INITRAMFS_END_POINTER, 4), (INITRAMFS_OFFSET, INITRAMFS_LIMIT + 4)):
        masked[offset:offset + size] = bytes(size)
    return sha(masked), sha(cpio)


def family_fields(dtb, plain, header, vbmeta, fingerprint,
                  fingerprint_offset, salt_offset, hash_size_offset, hash_digest_offset):
    """Pin structural fields; keep per-build fingerprint and salt on the phone."""
    header = bytearray(header)
    header_os = struct.unpack_from("<I", header, 44)[0] >> 11  # keep Android version; allow security patch dates
    for offset, size in ((8, 4), (16, 4), (44, 4), (576, 32)):
        header[offset:offset + size] = bytes(size)
    vbmeta = bytearray(vbmeta)
    for offset, size in ((120, 4), (hash_size_offset, 8), (hash_digest_offset, 32),
                         (salt_offset, 32), (fingerprint_offset, len(fingerprint))):
        vbmeta[offset:offset + size] = bytes(size)
    stock_sha, builtin_cpio_sha = stock_identity(plain)
    dtb_set = dtbs(dtb)
    return {
        "FAMILY_STOCK_SHA": stock_sha,
        "FAMILY_BUILTIN_CPIO_SHA": builtin_cpio_sha,
        "FAMILY_HOST_FIELDS": "+".join(map(str, HOST_FIELDS)),
        "FAMILY_TIME_FIELDS": "+".join(map(str, TIME_FIELDS)),
        "FAMILY_BUILD_ID_OFFSET": BUILD_ID_OFFSET,
        "FAMILY_BUILTIN_OFFSET": INITRAMFS_OFFSET,
        "FAMILY_BUILTIN_LIMIT": INITRAMFS_LIMIT,
        "FAMILY_BUILTIN_PTR": INITRAMFS_END_POINTER,
        "FAMILY_BUILTIN_MTIMES": "+".join(map(str, NEWC_MTIMES)),
        "FAMILY_DTB_SET_SHA": sha("".join(dtb_set).encode("ascii")),
        "FAMILY_DTB_COUNT": len(dtb_set),
        "FAMILY_HEADER_OS": header_os,
        "FAMILY_HEADER_SHA": sha(header),
        "FAMILY_VBMETA_SHA": sha(vbmeta),
        "FAMILY_FINGERPRINT_OFFSET": fingerprint_offset,
        "FAMILY_FINGERPRINT_SIZE": len(fingerprint),
        "FAMILY_SALT_OFFSET": salt_offset,
    }
