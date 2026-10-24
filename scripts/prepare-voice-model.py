#!/usr/bin/env python3
"""Prepare the pinned local ECAPA-TDNN Core ML resources for PocketBridge."""

from __future__ import annotations

import argparse
import ast
import hashlib
import math
import os
import shutil
import stat
import struct
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath


MODEL_REVISION = "63b5971457021835bf1703dddf9ab34148646b4f"
FRONTEND_REVISION = "speechbrain-fbank-v1"
MODEL_ID = f"enzolabs/ecapa-tdnn-coreml@{MODEL_REVISION}+{FRONTEND_REVISION}"
ARCHIVE_URL = (
    "https://huggingface.co/enzolabs/ecapa-tdnn-coreml/resolve/"
    f"{MODEL_REVISION}/ecapa-tdnn-coreml.zip?download=true"
)
ARCHIVE_SHA256 = "a511d5d3152db180a8831eb7b384151db0b80b162c2ab4487982f6c65246136f"
ARCHIVE_SIZE = 38_807_479
ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "ios" / "PocketBridge" / "VoiceModel"
CACHE = ROOT / "artifacts" / "voice-profile-r8" / "ecapa-tdnn-coreml.zip"
ARCHIVE_ROOT = "chirp-speaker-v2/"

MODEL_FILES = {
    "speaker.mlmodelc/weights/weight.bin": 41_624_768,
    "speaker.mlmodelc/metadata.json": 2_383,
    "speaker.mlmodelc/model.mil": 163_372,
    "speaker.mlmodelc/coremldata.bin": 403,
    "speaker.mlmodelc/analytics/coremldata.bin": 243,
}
EXPECTED_FILES = {
    f"{ARCHIVE_ROOT}mel_filterbank.npy": 64_448,
    f"{ARCHIVE_ROOT}window.npy": 1_728,
    **{f"{ARCHIVE_ROOT}{path}": size for path, size in MODEL_FILES.items()},
}
EXPECTED_DIRECTORIES = {
    ARCHIVE_ROOT,
    f"{ARCHIVE_ROOT}speaker.mlmodelc/",
    f"{ARCHIVE_ROOT}speaker.mlmodelc/weights/",
    f"{ARCHIVE_ROOT}speaker.mlmodelc/analytics/",
}
EXPECTED_ENTRIES = set(EXPECTED_FILES) | EXPECTED_DIRECTORIES


class PreparationError(Exception):
    pass


def sha256_file(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


def verify_archive(path: Path) -> None:
    digest, size = sha256_file(path)
    if size != ARCHIVE_SIZE or digest != ARCHIVE_SHA256:
        raise PreparationError("The model archive does not match the pinned size and SHA-256.")


def download_archive(destination: Path) -> Path:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        verify_archive(destination)
        return destination

    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(prefix=".ecapa-", suffix=".zip", dir=destination.parent, delete=False) as target:
            temporary_path = Path(target.name)
            request = urllib.request.Request(ARCHIVE_URL, headers={"User-Agent": "PocketBridge-model-prep/1"})
            with urllib.request.urlopen(request, timeout=60) as response:
                digest = hashlib.sha256()
                size = 0
                while chunk := response.read(1024 * 1024):
                    size += len(chunk)
                    if size > ARCHIVE_SIZE:
                        raise PreparationError("The downloaded model archive is larger than expected.")
                    digest.update(chunk)
                    target.write(chunk)
        if size != ARCHIVE_SIZE or digest.hexdigest() != ARCHIVE_SHA256:
            raise PreparationError("The downloaded model archive failed its pinned size or SHA-256 check.")
        os.replace(temporary_path, destination)
        temporary_path = None
        return destination
    except PreparationError:
        raise
    except Exception as error:
        raise PreparationError(f"The pinned model archive could not be downloaded: {error}") from None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def parse_npy(data: bytes, expected_shape: tuple[int, ...], label: str) -> bytes:
    if len(data) < 10 or data[:6] != b"\x93NUMPY":
        raise PreparationError(f"{label} is not a NumPy array file.")
    major, minor = data[6], data[7]
    if major == 1:
        header_size = struct.unpack_from("<H", data, 8)[0]
        header_start = 10
    elif major in (2, 3):
        if len(data) < 12:
            raise PreparationError(f"{label} has a truncated NumPy header.")
        header_size = struct.unpack_from("<I", data, 8)[0]
        header_start = 12
    else:
        raise PreparationError(f"{label} uses an unsupported NumPy format version.")
    header_end = header_start + header_size
    if header_end > len(data):
        raise PreparationError(f"{label} has a truncated NumPy header.")
    encoding = "utf-8" if major == 3 else "latin1"
    try:
        header = ast.literal_eval(data[header_start:header_end].decode(encoding).strip())
    except (SyntaxError, ValueError, UnicodeDecodeError):
        raise PreparationError(f"{label} has an invalid NumPy header.") from None
    if not isinstance(header, dict) or header.get("descr") != "<f4":
        raise PreparationError(f"{label} must use little-endian float32 values.")
    if header.get("fortran_order") is not False or tuple(header.get("shape", ())) != expected_shape:
        raise PreparationError(f"{label} has an unexpected layout or shape.")

    value_count = math.prod(expected_shape)
    payload = data[header_end:]
    if len(payload) != value_count * 4:
        raise PreparationError(f"{label} has an unexpected payload size.")
    if any(not math.isfinite(value[0]) for value in struct.iter_unpack("<f", payload)):
        raise PreparationError(f"{label} contains a non-finite value.")
    return payload


def inspect_archive(path: Path) -> zipfile.ZipFile:
    try:
        archive = zipfile.ZipFile(path)
        infos = archive.infolist()
        names = [info.filename for info in infos]
        if len(names) != len(set(names)) or set(names) != EXPECTED_ENTRIES:
            archive.close()
            raise PreparationError("The model archive contains missing or unexpected paths.")
        for info in infos:
            name = info.filename
            parsed = PurePosixPath(name)
            mode = info.external_attr >> 16
            file_type = stat.S_IFMT(mode)
            if ("\\" in name or parsed.is_absolute() or ".." in parsed.parts
                    or name.startswith("/") or (file_type == stat.S_IFLNK)):
                archive.close()
                raise PreparationError("The model archive contains an unsafe path or symlink.")
            if info.flag_bits & 0x1:
                archive.close()
                raise PreparationError("Encrypted model archive entries are not supported.")
            if name in EXPECTED_DIRECTORIES:
                if not info.is_dir() or (file_type not in (0, stat.S_IFDIR)):
                    archive.close()
                    raise PreparationError("The model archive has an unexpected directory entry.")
            elif info.is_dir() or file_type not in (0, stat.S_IFREG):
                archive.close()
                raise PreparationError("The model archive has an unexpected file entry.")
            elif info.file_size != EXPECTED_FILES[name]:
                archive.close()
                raise PreparationError("The model archive contains a file with an unexpected size.")
        if archive.testzip() is not None:
            archive.close()
            raise PreparationError("The model archive failed its CRC check.")
        return archive
    except zipfile.BadZipFile:
        raise PreparationError("The pinned model archive is not a valid ZIP file.") from None


def write_resource(archive: zipfile.ZipFile, name: str, destination: Path) -> None:
    source = archive.open(name)
    with source, destination.open("xb") as target:
        shutil.copyfileobj(source, target, length=1024 * 1024)


def remove_path(path: Path) -> None:
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink(missing_ok=True)


def install_resources(archive_path: Path) -> None:
    verify_archive(archive_path)
    archive = inspect_archive(archive_path)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".VoiceModel-", dir=OUTPUT.parent))
    backup: Path | None = None
    try:
        root = ARCHIVE_ROOT
        # The archive window is Hann; the training source uses periodic Hamming.
        filter_payload = parse_npy(archive.read(f"{root}mel_filterbank.npy"), (80, 201), "mel_filterbank.npy")
        for relative, size in MODEL_FILES.items():
            destination = staging / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            name = f"{root}{relative}"
            if archive.getinfo(name).file_size != size:
                raise PreparationError("The compiled model file size does not match the pinned archive.")
            write_resource(archive, name, destination)

        (staging / "mel_filterbank.f32").write_bytes(filter_payload)
        (staging / "model-id.txt").write_text(f"{MODEL_ID}\n", encoding="ascii")
        archive.close()

        if OUTPUT.is_symlink():
            raise PreparationError("The generated VoiceModel path is a symlink.")
        if OUTPUT.exists():
            backup = OUTPUT.with_name(f".VoiceModel-old-{os.getpid()}")
            if backup.exists():
                remove_path(backup)
            os.replace(OUTPUT, backup)
        try:
            os.replace(staging, OUTPUT)
        except Exception:
            if backup is not None and backup.exists():
                os.replace(backup, OUTPUT)
                backup = None
            raise
        if backup is not None:
            remove_path(backup)
            backup = None
    finally:
        archive.close()
        if staging.exists():
            remove_path(staging)
        if backup is not None and backup.exists():
            if not OUTPUT.exists():
                os.replace(backup, OUTPUT)
            else:
                remove_path(backup)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="use a previously downloaded model ZIP")
    args = parser.parse_args()
    try:
        archive_path = args.archive.expanduser().resolve() if args.archive else download_archive(CACHE)
        if not archive_path.is_file():
            raise PreparationError("The model archive path is not a file.")
        install_resources(archive_path)
    except PreparationError as error:
        print(f"prepare-voice-model: {error}", file=sys.stderr)
        return 1
    print(f"Prepared {MODEL_ID} at {OUTPUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
