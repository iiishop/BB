#!/usr/bin/env python3
"""Validate, zip and inspect the BB Windows Flutter bundle.

The Windows package must be self-contained: ``ffmpeg/ffmpeg.exe`` ships next to
the application and is executed from the installation directory, never from the
system PATH. This script checks the bundle layout, proves the bundled binary
runs with a PATH that has no ffmpeg/ffprobe, mirrors the client's cover
extraction arguments, zips the bundle and then re-extracts the archive into a
path containing spaces and Chinese characters for a second validation.

On non-Windows hosts the binary smoke is reported as NOT_RUN; the layout, zip
and re-extraction checks still run (they are what CI and tests need).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    # Windows runners default to cp1252; summaries contain Chinese paths.
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

APP_EXECUTABLE = "bb_client.exe"
FFMPEG_RELATIVE = "ffmpeg/ffmpeg.exe"
REQUIRED_RELATIVE = (
    APP_EXECUTABLE,
    FFMPEG_RELATIVE,
    "ffmpeg/FFMPEG-LICENSE.txt",
    "ffmpeg/FFMPEG-NOTICE.txt",
)
FORBIDDEN_BINARIES = ("ffprobe.exe", "ffplay.exe")
FLUTTER_ASSETS_PREFIX = "data/flutter_assets/"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
MIN_FFMPEG_BYTES = 90 * 1024 * 1024
MIN_APP_BYTES = 50 * 1024
MIN_ZIP_BYTES = 20 * 1024 * 1024


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_bundle(
    bundle: Path,
    *,
    min_ffmpeg_bytes: int = MIN_FFMPEG_BYTES,
    min_app_bytes: int = MIN_APP_BYTES,
) -> dict[str, object]:
    bundle = Path(bundle)
    if not bundle.is_dir():
        raise RuntimeError(f"bundle directory not found: {bundle}")
    problems: list[str] = []
    for relative in REQUIRED_RELATIVE:
        if not (bundle / relative).is_file():
            problems.append(f"missing {relative}")
    if not (bundle / "data" / "flutter_assets").is_dir():
        problems.append("missing data/flutter_assets/")
    app = bundle / APP_EXECUTABLE
    if app.is_file() and app.stat().st_size < min_app_bytes:
        problems.append(f"{APP_EXECUTABLE} is only {app.stat().st_size} bytes")
    ffmpeg = bundle / FFMPEG_RELATIVE
    if ffmpeg.is_file():
        if ffmpeg.stat().st_size < min_ffmpeg_bytes:
            problems.append(
                f"{FFMPEG_RELATIVE} is only {ffmpeg.stat().st_size} bytes"
            )
        with ffmpeg.open("rb") as handle:
            if handle.read(2) != b"MZ":
                problems.append(f"{FFMPEG_RELATIVE} is not a Windows PE file")
    for path in bundle.rglob("*"):
        if path.is_file() and path.name.lower() in FORBIDDEN_BINARIES:
            problems.append(f"unused tool must not be bundled: {path.relative_to(bundle)}")
    if problems:
        raise RuntimeError("; ".join(problems))
    return {
        "bundle": str(bundle),
        "app_bytes": app.stat().st_size,
        "ffmpeg_bytes": ffmpeg.stat().st_size,
        "ffmpeg_sha256": sha256_file(ffmpeg),
    }


def build_clean_env(base: dict[str, str] | None = None) -> dict[str, str]:
    """Environment whose PATH cannot resolve a system ffmpeg/ffprobe."""
    env = dict(os.environ if base is None else base)
    if os.name == "nt":
        root = env.get("SystemRoot", r"C:\Windows")
        env["PATH"] = f"{root}\\System32;{root}"
    else:
        env["PATH"] = "/usr/bin:/bin"
    return env


def assert_no_system_ffmpeg(env: dict[str, str]) -> None:
    for tool in ("ffmpeg", "ffprobe"):
        if shutil.which(tool, path=env["PATH"]):
            raise RuntimeError(
                f"PATH still resolves {tool}; the bundled binary smoke would be masked"
            )


def _run(command: list[str], env: dict[str, str], timeout: int = 180) -> str:
    completed = subprocess.run(
        command,
        env=env,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    stdout = completed.stdout.decode("utf-8", errors="replace")
    stderr = completed.stderr.decode("utf-8", errors="replace")
    if completed.returncode != 0:
        raise RuntimeError(
            f"{command[0]} exited {completed.returncode}: {stderr.strip()}"
        )
    return stdout


def cover_smoke(bundle: Path, workspace: Path) -> dict[str, object]:
    """Prove the packaged ffmpeg can produce the cover the client asks for."""
    if os.name != "nt":
        return {
            "status": "NOT_RUN",
            "reason": "binary smoke requires Windows (the .exe is not executable here)",
        }
    bundle = Path(bundle)
    workspace = Path(workspace)
    workspace.mkdir(parents=True, exist_ok=True)
    ffmpeg = bundle / "ffmpeg" / "ffmpeg.exe"
    env = build_clean_env()
    assert_no_system_ffmpeg(env)
    version = _run([str(ffmpeg), "-version"], env).splitlines()[0]
    sample = workspace / "sample.mp4"
    _run(
        [
            str(ffmpeg),
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "color=c=orange:s=64x64:d=1",
            "-pix_fmt",
            "yuv420p",
            "-movflags",
            "+faststart",
            "-y",
            str(sample),
        ],
        env,
    )
    cover = workspace / "cover.png"
    # Same arguments the client uses for a cover, with pipe:1 replaced by a
    # file so the archive check can inspect the PNG.
    _run(
        [
            str(ffmpeg),
            "-v",
            "error",
            "-ss",
            "0",
            "-i",
            str(sample),
            "-frames:v",
            "1",
            "-f",
            "image2",
            "-vcodec",
            "png",
            "-y",
            str(cover),
        ],
        env,
    )
    payload = cover.read_bytes()
    if len(payload) < 100 or payload[:8] != PNG_SIGNATURE:
        raise RuntimeError("bundled ffmpeg produced no valid PNG cover")
    return {
        "status": "PASS",
        "ffmpeg_version": version,
        "ffmpeg_path": str(ffmpeg),
        "clean_path": env["PATH"],
        "sample_bytes": sample.stat().st_size,
        "cover_bytes": len(payload),
    }


def build_zip(bundle: Path, output_zip: Path) -> None:
    bundle = Path(bundle)
    output_zip = Path(output_zip)
    output_zip.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(
        output_zip, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6
    ) as archive:
        for path in sorted(bundle.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(bundle).as_posix())


def inspect_zip(
    zip_path: Path, *, min_zip_bytes: int = MIN_ZIP_BYTES
) -> dict[str, object]:
    zip_path = Path(zip_path)
    if not zip_path.is_file():
        raise RuntimeError(f"missing archive: {zip_path}")
    if zip_path.stat().st_size < min_zip_bytes:
        raise RuntimeError(
            f"{zip_path} is only {zip_path.stat().st_size} bytes; incomplete package"
        )
    names: set[str] = set()
    with zipfile.ZipFile(zip_path) as archive:
        names = {info.filename.replace("\\", "/") for info in archive.infolist()}
    problems: list[str] = []
    for relative in REQUIRED_RELATIVE:
        if relative not in names:
            problems.append(f"archive missing {relative}")
    if not any(name.startswith(FLUTTER_ASSETS_PREFIX) for name in names):
        problems.append("archive missing data/flutter_assets/")
    for name in names:
        if Path(name).name.lower() in FORBIDDEN_BINARIES:
            problems.append(f"archive contains unused tool {name}")
    if problems:
        raise RuntimeError("; ".join(problems))
    return {
        "zip": str(zip_path),
        "zip_bytes": zip_path.stat().st_size,
        "zip_sha256": sha256_file(zip_path),
        "entries": len(names),
    }


def extract_and_recheck(
    zip_path: Path,
    workspace: Path,
    *,
    min_ffmpeg_bytes: int = MIN_FFMPEG_BYTES,
    min_app_bytes: int = MIN_APP_BYTES,
) -> dict[str, object]:
    target = Path(workspace) / "BB 测试 包"
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)
    with zipfile.ZipFile(zip_path) as archive:
        archive.extractall(target)
    bundle = validate_bundle(
        target, min_ffmpeg_bytes=min_ffmpeg_bytes, min_app_bytes=min_app_bytes
    )
    smoke = cover_smoke(target, target / "smoke")
    return {
        "extracted_to": str(target),
        "bundle": bundle,
        "smoke": smoke,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--out", default="dist")
    parser.add_argument("--version", required=True)
    parser.add_argument("--name", default=None)
    args = parser.parse_args(argv)

    name = args.name or f"bb-{args.version}-windows-x64"
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    log: list[str] = []
    started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    try:
        bundle_report = validate_bundle(Path(args.bundle))
        log.append(f"bundle: {json.dumps(bundle_report, ensure_ascii=False)}")
        smoke = cover_smoke(Path(args.bundle), out / "smoke")
        log.append(f"bundle smoke: {json.dumps(smoke, ensure_ascii=False)}")

        zip_path = out / f"{name}.zip"
        build_zip(Path(args.bundle), zip_path)
        archive_report = inspect_zip(zip_path)
        log.append(f"archive: {json.dumps(archive_report, ensure_ascii=False)}")

        with tempfile.TemporaryDirectory() as temporary:
            extracted = extract_and_recheck(zip_path, temporary)
        log.append(f"extracted recheck: {json.dumps(extracted, ensure_ascii=False)}")

        sums = out / "SHA256SUMS.txt"
        sums.write_text(
            f"{archive_report['zip_sha256']}  {zip_path.name}\n",
            encoding="utf-8",
        )
        summary = {
            "name": name,
            "version": args.version,
            "generated_at": started,
            "archive": archive_report,
            "bundle": bundle_report,
            "bundle_smoke": smoke,
            "extracted_recheck": extracted,
            "sha256sums": str(sums),
        }
        (out / "package-summary.json").write_text(
            json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        log.append("PASS")
        print(json.dumps(summary, ensure_ascii=False, indent=2))
        return 0
    finally:
        (out / "package-windows.log").write_text(
            "\n".join(log) + "\n", encoding="utf-8"
        )


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, zipfile.BadZipFile) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
