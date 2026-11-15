#!/usr/bin/env python3
"""Validate, zip and inspect the BB Windows Flutter bundle.

The Windows package must be self-contained: ``ffmpeg/ffmpeg.exe`` ships next to
the application and is executed from the installation directory, never from the
system PATH. FFmpeg is built from pinned sources by
``scripts/ci/build_ffmpeg_windows.sh``; the build manifest records the exact
source hashes, executable hash and configure flags.

This script refuses a bundle whose FFmpeg does not match the manifest (and the
optionally supplied expected executable hash), checks the license/notice set,
proves the bundled binary runs with a PATH that has no ffmpeg/ffprobe, decodes
the committed cover fixtures to PNG, zips the bundle and re-extracts the archive
into a path containing spaces and Chinese characters for a second validation.

On non-Windows hosts the binary smoke is reported as NOT_RUN; layout, hash,
license and zip checks still run.
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

from ffmpeg_pins import (
    FFMPEG_COMMIT,
    FFMPEG_FORBIDDEN_CONFIGURE,
    FFMPEG_REQUIRED_CONFIGURE,
    FFMPEG_SOURCE_SHA256,
    FFMPEG_VERSION,
    ZLIB_SOURCE_SHA256,
    ZLIB_VERSION,
)

if hasattr(sys.stdout, "reconfigure"):
    # Windows runners default to cp1252; summaries contain Chinese paths.
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

APP_EXECUTABLE = "bb_client.exe"
FFMPEG_RELATIVE = "ffmpeg/ffmpeg.exe"
MANIFEST_RELATIVE = "ffmpeg/BUILD-MANIFEST.txt"
REQUIRED_RELATIVE = (
    APP_EXECUTABLE,
    FFMPEG_RELATIVE,
    MANIFEST_RELATIVE,
    "ffmpeg/FFMPEG-LICENSE.txt",
    "ffmpeg/FFMPEG-LGPLv3.txt",
    "ffmpeg/FFMPEG-GPLv3.txt",
    "ffmpeg/ZLIB-LICENSE.txt",
    "ffmpeg/FFMPEG-NOTICE.txt",
)
LICENSE_MARKERS = {
    "ffmpeg/FFMPEG-LICENSE.txt": "GNU LESSER GENERAL PUBLIC LICENSE",
    "ffmpeg/FFMPEG-LGPLv3.txt": "Version 3",
    "ffmpeg/FFMPEG-GPLv3.txt": "GNU GENERAL PUBLIC LICENSE",
    "ffmpeg/ZLIB-LICENSE.txt": "This software is provided 'as-is'",
}
FORBIDDEN_BINARIES = ("ffprobe.exe", "ffplay.exe")
FLUTTER_ASSETS_PREFIX = "data/flutter_assets/"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
MIN_FFMPEG_BYTES = 10 * 1024 * 1024
MIN_APP_BYTES = 50 * 1024
MIN_ZIP_BYTES = 10 * 1024 * 1024
DEFAULT_SAMPLES = (
    "scripts/ci/fixtures/cover-smoke-h264.mp4",
    "scripts/ci/fixtures/cover-smoke-hevc.mp4",
    "scripts/ci/fixtures/cover-smoke-vp9.webm",
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_manifest(bundle: Path) -> dict[str, str]:
    manifest_path = Path(bundle) / MANIFEST_RELATIVE
    if not manifest_path.is_file():
        raise RuntimeError(f"missing {MANIFEST_RELATIVE}")
    values: dict[str, str] = {}
    for line in manifest_path.read_text(encoding="utf-8").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def validate_bundle(
    bundle: Path,
    *,
    min_ffmpeg_bytes: int = MIN_FFMPEG_BYTES,
    min_app_bytes: int = MIN_APP_BYTES,
    expected_ffmpeg_sha256: str | None = None,
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
            problems.append(
                f"unused tool must not be bundled: {path.relative_to(bundle)}"
            )
    for relative, marker in LICENSE_MARKERS.items():
        path = bundle / relative
        if path.is_file() and marker not in path.read_text(
            encoding="utf-8", errors="replace"
        ):
            problems.append(f"{relative} does not contain {marker!r}")
    if problems:
        raise RuntimeError("; ".join(problems))

    manifest = read_manifest(bundle)
    pins = {
        "format": "1",
        "ffmpeg_version": FFMPEG_VERSION,
        "ffmpeg_commit": FFMPEG_COMMIT,
        "ffmpeg_source_sha256": FFMPEG_SOURCE_SHA256,
        "zlib_version": ZLIB_VERSION,
        "zlib_source_sha256": ZLIB_SOURCE_SHA256,
    }
    for key, expected in pins.items():
        if manifest.get(key) != expected:
            problems.append(
                f"manifest {key}={manifest.get(key)!r} != pinned {expected!r}"
            )
    configure = manifest.get("configure", "")
    for flag in FFMPEG_REQUIRED_CONFIGURE:
        if flag not in configure:
            problems.append(f"manifest configure is missing {flag}")
    for flag in FFMPEG_FORBIDDEN_CONFIGURE:
        if flag in configure:
            problems.append(f"manifest configure must not contain {flag}")

    actual_sha256 = sha256_file(ffmpeg)
    if manifest.get("ffmpeg_exe_sha256") != actual_sha256:
        problems.append(
            "ffmpeg.exe SHA256 does not match BUILD-MANIFEST.txt "
            f"({actual_sha256} != {manifest.get('ffmpeg_exe_sha256')})"
        )
    if manifest.get("ffmpeg_exe_bytes") != str(ffmpeg.stat().st_size):
        problems.append("ffmpeg.exe size does not match BUILD-MANIFEST.txt")
    if expected_ffmpeg_sha256 and actual_sha256 != expected_ffmpeg_sha256:
        problems.append(
            "ffmpeg.exe SHA256 does not match the expected build output "
            f"({actual_sha256} != {expected_ffmpeg_sha256})"
        )
    notice = (bundle / "ffmpeg/FFMPEG-NOTICE.txt").read_text(
        encoding="utf-8", errors="replace"
    )
    for marker in (
        FFMPEG_VERSION,
        FFMPEG_COMMIT,
        FFMPEG_SOURCE_SHA256,
        ZLIB_VERSION,
        ZLIB_SOURCE_SHA256,
        "LGPL",
        "Corresponding source",
    ):
        if marker not in notice:
            problems.append(f"FFMPEG-NOTICE.txt is missing {marker!r}")
    if problems:
        raise RuntimeError("; ".join(problems))
    return {
        "bundle": str(bundle),
        "app_bytes": app.stat().st_size,
        "ffmpeg_bytes": ffmpeg.stat().st_size,
        "ffmpeg_sha256": actual_sha256,
        "ffmpeg_version": manifest.get("ffmpeg_version"),
        "ffmpeg_commit": manifest.get("ffmpeg_commit"),
        "zlib_version": manifest.get("zlib_version"),
        "imports": manifest.get("imports", ""),
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


def cover_smoke(
    bundle: Path,
    workspace: Path,
    samples: list[Path] | tuple[Path, ...] = (),
) -> dict[str, object]:
    """Prove the packaged ffmpeg can decode fixtures into the requested cover."""
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
    decoded: list[dict[str, object]] = []
    for sample in samples:
        sample = Path(sample)
        if not sample.is_file():
            raise RuntimeError(f"cover fixture not found: {sample}")
        cover = workspace / f"{sample.stem}.png"
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
            raise RuntimeError(
                f"bundled ffmpeg produced no valid PNG for {sample.name}"
            )
        decoded.append({"fixture": sample.name, "cover_bytes": len(payload)})
    if not decoded:
        raise RuntimeError("no cover fixtures were supplied to the package smoke")
    return {
        "status": "PASS",
        "ffmpeg_version": version,
        "ffmpeg_path": str(ffmpeg),
        "clean_path": env["PATH"],
        "decoded": decoded,
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


def remove_tree(path: Path) -> None:
    """Best-effort recursive delete; Windows may briefly lock a just-run .exe."""
    for _ in range(10):
        try:
            shutil.rmtree(path)
            return
        except FileNotFoundError:
            return
        except PermissionError:
            time.sleep(0.5)
    shutil.rmtree(path, ignore_errors=True)


def extract_and_recheck(
    zip_path: Path,
    workspace: Path,
    *,
    min_ffmpeg_bytes: int = MIN_FFMPEG_BYTES,
    min_app_bytes: int = MIN_APP_BYTES,
    expected_ffmpeg_sha256: str | None = None,
    samples: list[Path] | tuple[Path, ...] = (),
) -> dict[str, object]:
    target = Path(workspace) / "BB 测试 包"
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)
    with zipfile.ZipFile(zip_path) as archive:
        archive.extractall(target)
    bundle = validate_bundle(
        target,
        min_ffmpeg_bytes=min_ffmpeg_bytes,
        min_app_bytes=min_app_bytes,
        expected_ffmpeg_sha256=expected_ffmpeg_sha256,
    )
    smoke = cover_smoke(target, target / "smoke", samples)
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
    parser.add_argument(
        "--expected-ffmpeg-sha256",
        default=None,
        help="hash emitted by the build step; the bundle must match it",
    )
    parser.add_argument(
        "--samples",
        nargs="*",
        default=list(DEFAULT_SAMPLES),
        help="video fixtures decoded by the bundled ffmpeg (Windows only)",
    )
    args = parser.parse_args(argv)

    name = args.name or f"bb-{args.version}-windows-x64"
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    samples = [Path(path) for path in args.samples]
    log: list[str] = []
    started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    try:
        bundle_report = validate_bundle(
            Path(args.bundle),
            expected_ffmpeg_sha256=args.expected_ffmpeg_sha256,
        )
        log.append(f"bundle: {json.dumps(bundle_report, ensure_ascii=False)}")
        smoke = cover_smoke(Path(args.bundle), out / "smoke", samples)
        log.append(f"bundle smoke: {json.dumps(smoke, ensure_ascii=False)}")

        zip_path = out / f"{name}.zip"
        build_zip(Path(args.bundle), zip_path)
        archive_report = inspect_zip(zip_path)
        log.append(f"archive: {json.dumps(archive_report, ensure_ascii=False)}")

        temporary = tempfile.mkdtemp(prefix="bb-windows-recheck-")
        try:
            extracted = extract_and_recheck(
                zip_path,
                temporary,
                expected_ffmpeg_sha256=args.expected_ffmpeg_sha256,
                samples=samples,
            )
        finally:
            remove_tree(Path(temporary))
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
            "expected_ffmpeg_sha256": args.expected_ffmpeg_sha256,
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
