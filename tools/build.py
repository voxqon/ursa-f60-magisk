"""Build a multi-profile module. All paths are relative to this repository."""

import argparse
import gzip
import json
import os
import re
import subprocess
import struct
import sys
import tempfile
import zipfile
from pathlib import Path

from common import ROOT, avb_module, boot_parts, dtbs, fetch, kernel_config, local_path, sha, spec, split_kernel, verify_manifest
from family import family_fields


def released_kernel(download):
    # Keep supporting the original build after its official images rotate off mirrors.
    config = json.loads((ROOT / "config/f60-release.json").read_text(encoding="utf-8"))
    archive_path = fetch(config, ROOT / "out/ursa-f60-magisk-v2.2.0.zip", download)
    with zipfile.ZipFile(archive_path) as archive:
        prefix = f"payload/profiles/{config['target']}/"
        files = {name: archive.read(prefix + name) for name in ("kernel", "salt", "manifest.env")}
    return config, files


def run(*args, cwd=None):
    result = subprocess.run([str(arg) for arg in args], cwd=cwd,
                            capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"Tool failed: {args}\n{result.stdout}\n{result.stderr}")
    return result.stdout


def magisk_tools(download):
    config = json.loads((ROOT / "config/magisk.json").read_text(encoding="utf-8"))
    folder = ROOT / "out/tools"
    apk = fetch(config, folder / f"Magisk-v{config['name']}.apk", download)
    with zipfile.ZipFile(apk) as archive:
        arm64_sha = sha(archive.read("lib/arm64-v8a/libmagiskboot.so"))
        (folder / "magiskboot-arm64").write_bytes(
            archive.read("lib/arm64-v8a/libmagiskboot.so"))
        path = folder / "magiskboot"
        path.write_bytes(archive.read("lib/x86_64/libmagiskboot.so"))
        path.chmod(0o755)
    config["arm64_sha"] = arm64_sha
    return config, folder


def canonical_cpio(ramdisk, tools):
    with tempfile.TemporaryDirectory(prefix="canonical-", dir=ROOT / "out") as temp:
        temp = Path(temp)
        (temp / "ramdisk.raw").write_bytes(ramdisk)
        commands = [
            ["decompress", "ramdisk.raw", "ramdisk.cpio"],
            ["cpio", "ramdisk.cpio", "mkdir 000 .f60-canonical", "rm .f60-canonical"],
        ]
        for command in commands:
            if os.name == "nt":
                run("docker", "run", "--rm",
                    "--mount", f"type=bind,source={tools},target=/tools,readonly",
                    "--mount", f"type=bind,source={temp},target=/work",
                    "--workdir", "/work", "ubuntu:22.04", "/tools/magiskboot", *command)
            else:
                run(tools / "magiskboot", *command, cwd=temp)
        return sha((temp / "ramdisk.cpio").read_bytes())


def profile(target, tools, download, release=None, family=False):
    verify_manifest(target, download)
    stock_path = fetch(target["stock_boot"], local_path(target["stock_boot"]["file"]), download)
    stock = stock_path.read_bytes()
    raw_stock, ramdisk = boot_parts(stock)
    os_major = struct.unpack_from("<I", stock, 44)[0] >> 25
    if os_major < 13 or target["sdk"] != os_major + 20:
        raise ValueError("Target SDK does not match the Android version in the boot header")
    stock_gz, original_dtb, stock_plain = split_kernel(raw_stock)
    fixed_path = local_path(target["kernel"]["file"])
    original_dtbs = dtbs(original_dtb)
    if fixed_path.is_file():
        fixed_gz, rebuilt_dtb, fixed_plain = split_kernel(fixed_path.read_bytes())
        if original_dtbs != dtbs(rebuilt_dtb):
            raise ValueError(f"{target['id']}: rebuilt DTBs differ")
    elif release is not None:
        config, files = release
        if (target["kernel"]["revision"] != config["revision"] or
                sha("".join(original_dtbs).encode("ascii")) != config["dtb_set_sha256"]):
            raise ValueError(f"{target['id']}: released kernel does not match source or DTBs")
        fixed_gz = files["kernel"]
        fixed_plain = gzip.decompress(fixed_gz)
    else:
        raise FileNotFoundError(f"Missing {fixed_path}")
    config = kernel_config(stock_plain)
    if local_path(target["kernel"]["stock_config"]).read_text(encoding="utf-8") != config:
        raise ValueError("Pinned stock config differs from boot")
    if "CONFIG_INPUT_PRESS_NDT_F60=y" in config.splitlines():
        raise ValueError("Stock already enables F60; no repair payload is needed")
    expected = config.replace("# CONFIG_INPUT_PRESS_NDT_F60 is not set",
                              "CONFIG_INPUT_PRESS_NDT_F60=y")
    if expected == config or kernel_config(fixed_plain) != expected:
        raise ValueError("Rebuilt config changes must be limited to enabling F60")
    release = re.search(rb"Linux version ([^\s\x00]+)", fixed_plain)
    if not release:
        raise ValueError("Cannot determine kernel release")
    release = release.group(1).decode("ascii")
    if not re.fullmatch(r"[a-zA-Z0-9._+-]+", release):
        raise ValueError("Invalid kernel release")

    avb = avb_module()
    image = avb.ImageHandler(str(stock_path), read_only=True)
    try:
        footer, header, descriptors, _ = avb.Avb()._parse_image(image)
    finally:
        image._image.close()
    if footer is None or header.algorithm_type != 0 or header.authentication_data_block_size:
        raise ValueError("Only AVB NONE images are supported")
    if not 256 <= footer.vbmeta_size <= 65536:
        raise ValueError("Invalid vbmeta size")
    offset = 256 + header.descriptors_offset
    hashes = []
    for descriptor in descriptors:
        if isinstance(descriptor, avb.AvbHashDescriptor):
            hashes.append((descriptor, offset))
        elif not isinstance(descriptor, avb.AvbPropertyDescriptor):
            raise ValueError("Unsupported AVB descriptor")
        offset += len(descriptor.encode())
    fingerprints = [d.value.decode("utf-8") for d in descriptors
                    if isinstance(d, avb.AvbPropertyDescriptor)
                    and d.key == "com.android.build.boot.fingerprint"]
    if fingerprints and not all(f"/{target['incremental']}:" in value for value in fingerprints):
        raise ValueError("Target incremental ID does not match boot fingerprint metadata")
    if len(hashes) != 1:
        raise ValueError("Expected one boot hash descriptor")
    descriptor, offset = hashes[0]
    if (descriptor.partition_name != "boot" or descriptor.hash_algorithm != "sha256"
            or len(descriptor.salt) != 32 or len(descriptor.digest) != 32):
        raise ValueError("Unsupported hash descriptor")
    run(sys.executable, ROOT / "third_party/avb/avbtool.py",
        "verify_image", "--image", stock_path)
    size_offset = offset + 16
    salt_offset = offset + avb.AvbHashDescriptor.SIZE + len(descriptor.partition_name.encode("utf-8"))
    digest_offset = salt_offset + len(descriptor.salt)
    vbmeta = bytearray(stock[footer.vbmeta_offset:footer.vbmeta_offset + footer.vbmeta_size])
    for start, size in ((120, 4), (size_offset, 8), (digest_offset, 32)):
        vbmeta[start:start + size] = bytes(size)
    masked_footer = bytearray(stock[-64:])
    masked_footer[12:28] = bytes(16)
    masked_header = bytearray(stock[:4096])
    for start, size in ((8, 4), (16, 4), (576, 32)):
        masked_header[start:start + size] = bytes(size)
    manifest = {
        "TARGET_ID": target["id"],
        "TARGET_VERSION": target["lineage_version"],
        "TARGET_INCREMENTAL": target["incremental"],
        "TARGET_SDK": target["sdk"],
        "STOCK_CPIO_CANONICAL_SHA": target["stock_boot"].get("canonical_cpio_sha256")
        or canonical_cpio(ramdisk, tools),
        "IMAGE_SIZE": len(stock),
        "SOURCE_IMAGE_SIZE": len(stock),
        "PARTITION_SIZE": target["partition_size"],
        "STOCK_RAMDISK_SHA": sha(ramdisk),
        "STOCK_PLAIN_SHA": sha(stock_plain),
        "STOCK_PLAIN_SIZE": len(stock_plain),
        "FIXED_PLAIN_SHA": sha(fixed_plain),
        "FIXED_PLAIN_SIZE": len(fixed_plain),
        "HEADER_MASK_SHA": sha(masked_header),
        "FOOTER_MASK_SHA": sha(masked_footer),
        "VBMETA_MASK_SHA": sha(vbmeta),
        "VBMETA_SIZE": len(vbmeta),
        "HASH_SIZE_OFFSET": size_offset,
        "HASH_DIGEST_OFFSET": digest_offset,
        "STOCK_KERNEL_SHA": sha(stock_gz + original_dtb),
        "FIXED_KERNEL_SHA": sha(fixed_gz + original_dtb),
        "DTB_SHA": sha(original_dtb),
        "FIXED_RELEASE": release,
    }
    files = {
        "kernel": fixed_gz,
        "salt": descriptor.salt,
        "manifest.env": env_file(manifest),
    }
    if family and target.get("adaptive_family") and not fixed_path.is_file():
        if len(fingerprints) != 1:
            raise ValueError("Adaptive profiles require a single boot fingerprint")
        fingerprint = fingerprints[0].encode("ascii")
        source_vbmeta = stock[footer.vbmeta_offset:footer.vbmeta_offset + footer.vbmeta_size]
        if (source_vbmeta.count(fingerprint) != 1 or source_vbmeta.count(descriptor.salt) != 1
                or source_vbmeta[salt_offset:digest_offset] != descriptor.salt
                or source_vbmeta[digest_offset:digest_offset + 32] != descriptor.digest):
            raise ValueError("Cannot locate unique boot fingerprint, salt and digest")
        adaptive = family_fields(original_dtb, stock_plain, stock[:4096], source_vbmeta,
                                 fingerprint, source_vbmeta.index(fingerprint), salt_offset,
                                 size_offset, digest_offset)
        adaptive.update({key: manifest[key] for key in (
            "SOURCE_IMAGE_SIZE", "PARTITION_SIZE", "STOCK_PLAIN_SIZE", "FIXED_PLAIN_SHA", "FIXED_PLAIN_SIZE",
            "FOOTER_MASK_SHA", "VBMETA_SIZE", "HASH_SIZE_OFFSET", "HASH_DIGEST_OFFSET", "FIXED_RELEASE")})
        files["family"] = (adaptive, manifest["STOCK_RAMDISK_SHA"], manifest["STOCK_CPIO_CANONICAL_SHA"])
    return files


def env_file(values):
    for value in values.values():
        if not re.fullmatch(r"[a-zA-Z0-9._+-]+", str(value)):
            raise ValueError("Unsafe generated shell manifest value")
    return "".join(f"{key}='{value}'\n" for key, value in values.items()).encode("ascii")


def build(download=False, selected=None):
    config, tools = magisk_tools(download)
    apatch = json.loads((ROOT / "config/apatch.json").read_text(encoding="utf-8"))
    kptools = fetch(apatch["kptools"], tools / "libkptools.so", download)
    kpimg = fetch(apatch["kpimg"], tools / "kpimg", download)
    targets = [spec(path) for path in sorted((ROOT / "targets").glob("*.json"))
               if selected is None or path.stem in selected]
    if not targets or (selected and set(selected) != {t["id"] for t in targets}):
        raise ValueError("Missing target specifications")
    keys = [(t["lineage_version"], t["incremental"], t["sdk"]) for t in targets]
    if len(keys) != len(set(keys)) or len({t["id"] for t in targets}) != len(targets):
        raise ValueError("Duplicate or ambiguous ROM profiles")
    payload = {"engine.env": env_file({
        "MAGISK_NAME": config["name"],
        "MAGISK_CODE": config["code"],
        "MAGISKBOOT_ARM64_SHA": config["arm64_sha"],
        "APATCH_CODE": apatch["code"],
        "KPTOOLS_ARM64_SHA": apatch["kptools"]["sha256"],
        "KPIMG_SIZE": kpimg.stat().st_size,
    })}
    payload["tools/magiskboot"] = (tools / "magiskboot-arm64").read_bytes()
    payload["tools/kptools"] = kptools.read_bytes()
    payload["tools/kpimg"] = kpimg.read_bytes()
    release = None
    families = {}
    for target in targets:
        kernel_path = local_path(target["kernel"]["file"])
        if target.get("use_released_kernel") and not kernel_path.is_file() and release is None:
            release = released_kernel(download)
        if (release and target["id"] == release[0]["target"] and not kernel_path.is_file()
                and not local_path(target["stock_boot"]["file"]).exists()):
            files = release[1].copy()
            expected = env_file({"TARGET_ID": target["id"], "TARGET_VERSION": target["lineage_version"],
                                 "TARGET_INCREMENTAL": target["incremental"], "TARGET_SDK": target["sdk"],
                                 "PARTITION_SIZE": target["partition_size"]})
            if not set(expected.splitlines()) <= set(files["manifest.env"].splitlines()):
                raise ValueError("Pinned legacy profile does not match the target definition")
        else:
            files = profile(target, tools, download, release if target.get("use_released_kernel") else None,
                            family=selected is None)
        kernel = files.pop("kernel")
        kernel_id = sha(kernel)
        payload[f"kernels/{kernel_id}"] = kernel
        if "family" in files:
            adaptive, ramdisk, cpio = files.pop("family")
            name = target["adaptive_family"]
            adaptive.update(TARGET_ID=name, TARGET_SDK=target["sdk"], KERNEL_ID=kernel_id)
            pinned, raw_hashes, cpio_hashes = families.setdefault(name, (adaptive, set(), set()))
            if pinned != adaptive:
                raise ValueError(f"Inconsistent adaptive family: {name}")
            raw_hashes.add(ramdisk)
            cpio_hashes.add(cpio)
        files["manifest.env"] += env_file({"KERNEL_ID": kernel_id})
        for name, data in files.items():
            payload[f"profiles/{target['id']}/{name}"] = data
    if len(families) > 1:
        raise ValueError("Only one adaptive family is currently supported")
    for fields, raw_hashes, cpio_hashes in families.values():
        payload["family.env"] = env_file(dict(fields,
            FAMILY_RAMDISKS="+".join(sorted(raw_hashes)), FAMILY_CPIOS="+".join(sorted(cpio_hashes))))
    payload["SHA256SUMS"] = "".join(
        f"{sha(data)}  {name}\n" for name, data in sorted(payload.items())).encode("ascii")
    folder = ROOT / "module/payload"
    for name, data in payload.items():
        path = folder / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    result = dist / "ursa-f60-magisk.zip"
    entries = {path.name: path.read_bytes().replace(b"\r\n", b"\n")
               for path in (ROOT / "module").iterdir() if path.is_file()}
    entries.update({path.relative_to(ROOT / "module").as_posix(): path.read_bytes()
                    for path in (ROOT / "module/webroot").rglob("*") if path.is_file()})
    entries.update({"payload/" + name: data for name, data in payload.items()})
    entries["README.md"] = (ROOT / "README.md").read_bytes()
    entries["LICENSE"] = (ROOT / "LICENSE").read_bytes()
    with zipfile.ZipFile(result, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(entries.items()):
            info = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            executable = name.endswith(".sh") or name in (
                "payload/tools/magiskboot", "payload/tools/kptools")
            info.external_attr = (0o100755 if executable else 0o100644) << 16
            archive.writestr(info, data)
    result.with_suffix(".zip.sha256").write_text(
        f"{sha(result.read_bytes())}  {result.name}\n", encoding="ascii")
    (dist / "compatibility.json").write_text(json.dumps({
        "minimum_lineage_major": 20,
        "device": "ursa",
        "policy": "Exact profiles or a verified kernel family; unknown images are refused",
        "adaptive_families": list(families),
        "targets": targets,
    }, indent=2) + "\n", encoding="utf-8")
    print(result)
    print(sha(result.read_bytes()))
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fetch", action="store_true")
    parser.add_argument("--target", action="append", help="Build selected profile ID(s)")
    args = parser.parse_args()
    build(args.fetch, args.target)
