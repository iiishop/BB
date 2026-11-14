"""Disposable image derivatives; authorization belongs to the calling route."""

import hashlib
import io
import os
import tempfile
import threading
from pathlib import Path

from bb_auth_contract import ContractError
from bb_auth_contract.media import THUMB_MAX_BYTES, THUMB_MAX_EDGE
from PIL import Image, ImageOps

# Bound concurrent decodes without retaining an ever-growing per-media lock map.
_generation_slots = threading.BoundedSemaphore(2)


def encode(source: Path) -> bytes:
    with Image.open(source) as image:
        # Only the first frame is a preview. JPEG draft avoids a full-size decode
        # where the codec supports it; thumbnail preserves aspect and never upscales.
        image.seek(0)
        image.draft("RGB", (THUMB_MAX_EDGE, THUMB_MAX_EDGE))
        image.thumbnail((THUMB_MAX_EDGE, THUMB_MAX_EDGE))
        oriented = ImageOps.exif_transpose(image)
        rgba = oriented.convert("RGBA")
        pixels = Image.new("RGB", rgba.size, "white")
        pixels.paste(rgba, mask=rgba.getchannel("A"))
    # A fresh pixel image carries none of the input EXIF/ICC/XMP metadata.
    while True:
        for quality in (80, 65, 50, 35):
            output = io.BytesIO()
            pixels.save(output, format="JPEG", quality=quality, optimize=True)
            data = output.getvalue()
            if len(data) <= THUMB_MAX_BYTES:
                return data
        # Dimension reduction guarantees the byte cap even for high entropy input.
        pixels = pixels.resize(
            (max(1, pixels.width // 2), max(1, pixels.height // 2)),
            Image.Resampling.LANCZOS,
        )


def thumbnail(directory: Path, media_id: str) -> tuple[Path, str]:
    """Publish complete files only. Caller passes an authorized DB-generated ID."""
    destination = directory / "derivatives" / "thumb-v1" / (media_id + ".jpg")
    temporary = None
    try:
        with _generation_slots:
            if not destination.is_file():
                data = encode(directory / media_id)
                destination.parent.mkdir(parents=True, exist_ok=True)
                # Unique names also permit independent server processes to race
                # safely. mkstemp creates mode 0600 on POSIX, even before writing.
                fd, name = tempfile.mkstemp(
                    prefix=media_id + ".", suffix=".tmp", dir=destination.parent
                )
                temporary = Path(name)
                with os.fdopen(fd, "wb") as stream:
                    stream.write(data)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, destination)
            # At most 64 KiB; content-derived ETag survives cache deletion/restart.
            etag = '"' + hashlib.sha256(destination.read_bytes()).hexdigest() + '"'
        return destination, etag
    except (OSError, ValueError, SyntaxError, Image.DecompressionBombError):
        raise ContractError(
            503, "thumbnail_unavailable", "缩略图暂不可用，请重试"
        ) from None
    finally:
        if temporary is not None:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                # A leftover unique temp file cannot be served as a derivative.
                pass
