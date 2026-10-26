"""Validated target inputs and boot parsing; Python standard library only."""

import hashlib
import importlib.util
import json
import re
import struct
import urllib.request
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def local_path(name):
    path = (ROOT / name).resolve()
    if not path.is_relative_to(ROOT):
        raise ValueError("Input paths must remain inside the repository")
    return path


def spec(path):
    target = json.loads(Path(path).read_text(encoding="utf-8"))
    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,100}", target["id"]):
        raise ValueError("Invalid profile ID")
    version = target["lineage_version"]
    if not re.fullmatch(r"\d+(?:\.\d+)*-\d{8}-[A-Z0-9_]+-ursa", version):
        raise ValueError("Invalid ursa LineageOS version")
    if int(version.split(".")[0].split("-")[0]) < 20 or target["device"] != "ursa":
        raise ValueError("Only ursa LineageOS 20+ targets are accepted")
    if not re.fullmatch(r"[a-zA-Z0-9._-]+", target["incremental"]):
        raise ValueError("Invalid incremental build ID")
    if type(target["sdk"]) is not int or target["sdk"] < 33:
        raise ValueError("SDK 33 or later required")
    partition_size = target.get("partition_size")
    if (type(partition_size) is not int or not 16777216 <= partition_size <= 134217728
            or partition_size % 4096):
        raise ValueError("A measured, page-aligned boot partition size is required")
    if not re.fullmatch(r"[0-9a-f]{40}", target["kernel"]["revision"]):
        raise ValueError("A pinned full kernel revision is required")
    for entry in (target["stock_boot"], target["build_manifest"], target["compiler"]):
        if not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]):
            raise ValueError("SHA-256 pins are required")
        if not entry["url"].startswith("https://"):
            raise ValueError("Downloads require HTTPS")
    for name in (target["stock_boot"]["file"], target["kernel"]["file"],
                 target["kernel"]["stock_config"]):
        local_path(name)
    return target


def fetch(entry, destination, enabled=False):
    destination = Path(destination)
    if destination.exists():
        if sha(destination.read_bytes()) != entry["sha256"]:
            raise ValueError(f"Hash mismatch: {destination}")
        return destination
    if not enabled:
        raise FileNotFoundError(f"Missing {destination}; use --fetch or provide the pinned file")
    destination.parent.mkdir(parents=True, exist_ok=True)
    data = urllib.request.urlopen(entry["url"], timeout=90).read()
    if sha(data) != entry["sha256"]:
        raise ValueError(f"Download hash mismatch: {destination}")
    destination.write_bytes(data)
    return destination


def boot_parts(data):
    if len(data) > 134217728 or len(data) % 4096 or data[:8] != b"ANDROID!":
        raise ValueError("Unsupported image size or magic")
    kernel_size = struct.unpack_from("<I", data, 8)[0]
    ramdisk_size = struct.unpack_from("<I", data, 16)[0]
    if struct.unpack_from("<I", data, 36)[0] != 4096:
        raise ValueError("Only 4096-byte pages are supported")
    if struct.unpack_from("<I", data, 40)[0] != 1:
        raise ValueError("Only boot header v1 is supported")
    if struct.unpack_from("<I", data, 24)[0] or struct.unpack_from("<I", data, 1632)[0]:
        raise ValueError("Unexpected second-stage or recovery DTBO")
    roff = 4096 + (kernel_size + 4095) // 4096 * 4096
    end = roff + (ramdisk_size + 4095) // 4096 * 4096
    if not kernel_size or not ramdisk_size or end >= len(data) - 8192:
        raise ValueError("Invalid boot component sizes")
    return data[4096:4096 + kernel_size], data[roff:roff + ramdisk_size]


def split_kernel(kernel):
    decoder = zlib.decompressobj(31)
    plain = decoder.decompress(kernel)
    if not decoder.eof or not decoder.unused_data:
        raise ValueError("Expected gzip kernel followed by DTBs")
    return kernel[:-len(decoder.unused_data)], decoder.unused_data, plain


def dtbs(data):
    result = []
    while data:
        if len(data) < 40:
            raise ValueError("Truncated DTB")
        magic, size = struct.unpack_from(">II", data)
        if magic != 0xD00DFEED or not 40 <= size <= len(data):
            raise ValueError("Invalid appended DTB")
        result.append(sha(data[:size]))
        data = data[size:]
    return sorted(result)


def kernel_config(plain):
    start = plain.find(b"IKCFG_ST")
    if start < 0:
        raise ValueError("Missing embedded kernel configuration")
    return zlib.decompress(plain[start + 8:], 31).decode("utf-8")


def avb_module():
    path = ROOT / "third_party/avb/avbtool.py"
    module_spec = importlib.util.spec_from_file_location("f60_avbtool", path)
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    return module


def verify_manifest(target, download=False):
    path = fetch(target["build_manifest"],
                 ROOT / "inputs" / target["id"] / "build-manifest.xml", download)
    manifest = ET.fromstring(path.read_bytes())
    projects = [node for node in manifest.findall("project")
                if node.get("path") == "kernel/xiaomi/sdm845"]
    if len(projects) != 1 or projects[0].get("revision") != target["kernel"]["revision"]:
        raise ValueError("Kernel revision does not match the pinned ROM build manifest")
    return path
