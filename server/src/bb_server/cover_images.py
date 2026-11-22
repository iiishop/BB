"""Decode profile cover sources and derive one bounded display image."""

import io
import warnings
from dataclasses import dataclass

from bb_auth_contract import ContractError
from bb_auth_contract.cover import MAX_COVER_BYTES, MAX_DISPLAY_BYTES
from PIL import Image, ImageChops, ImageCms, ImageFilter, ImageOps, ImageStat

MAX_PIXELS = 24_000_000
DISPLAY_EDGE = 1600
SIGNATURE_EDGE = 128
ASPECT_TOLERANCE = 0.005
FORMATS = {"PNG": "image/png", "JPEG": "image/jpeg", "WEBP": "image/webp"}


@dataclass
class CoverSource:
    pixels: Image.Image
    signature: bytes
    tone: int
    safe_original: bool
    mime_type: str

    @property
    def aspect(self):
        return self.pixels.width / self.pixels.height


def _safe_container(data: bytes, image: Image.Image) -> bool:
    """Keep clean, static inputs byte-for-byte. Strip private metadata otherwise."""
    if image.format == "JPEG":
        return (
            set(image.info)
            <= {
                "jfif",
                "jfif_version",
                "jfif_unit",
                "jfif_density",
                "adobe",
                "adobe_transform",
            }
            and all(tag in {"APP0", "APP14"} for tag, _ in image.applist)
            and data.endswith(b"\xff\xd9")
            and image.mode in {"L", "RGB"}
        )
    if image.format == "PNG":
        chunks = {
            b"IHDR",
            b"PLTE",
            b"tRNS",
            b"IDAT",
            b"IEND",
            b"gAMA",
            b"cHRM",
            b"sRGB",
        }
        offset = 8
        while offset + 12 <= len(data):
            size = int.from_bytes(data[offset : offset + 4], "big")
            chunk = data[offset + 4 : offset + 8]
            if chunk not in chunks:
                return False
            offset += size + 12
            if chunk == b"IEND":
                return offset == len(data)
        return False
    if int.from_bytes(data[4:8], "little") + 8 != len(data):
        return False
    offset = 12
    while offset + 8 <= len(data):
        chunk = data[offset : offset + 4]
        if chunk not in {b"VP8 ", b"VP8L", b"VP8X", b"ALPH"}:
            return False
        size = int.from_bytes(data[offset + 4 : offset + 8], "little")
        offset += size + (size % 2) + 8
    return offset == len(data)


def _color_pixels(image: Image.Image) -> Image.Image:
    ImageOps.exif_transpose(image, in_place=True)
    alpha = (
        image.convert("RGBA").getchannel("A") if image.has_transparency_data else None
    )
    icc = image.info.get("icc_profile")
    if icc:
        color = image if image.mode in {"RGB", "L", "CMYK"} else image.convert("RGB")
        pixels = ImageCms.profileToProfile(
            color, io.BytesIO(icc), ImageCms.createProfile("sRGB"), outputMode="RGB"
        )
    else:
        # Pillow's direct I;16 -> RGB conversion clips instead of scaling.
        if image.mode.startswith("I;16"):
            image = image.convert("I").point(lambda value: value / 257).convert("L")
        pixels = image.convert("RGB")
    if alpha is not None and alpha.getextrema()[0] < 255:
        pixels.putalpha(alpha)
    pixels.info.clear()
    return pixels


def _normalized_pixels(pixels: Image.Image, size: tuple[int, int]) -> Image.Image:
    preview = pixels.resize(size, Image.Resampling.LANCZOS).convert("RGBA")
    normalized = Image.alpha_composite(Image.new("RGBA", size, "white"), preview)
    normalized.putalpha(preview.getchannel("A"))
    return normalized


def decode_source(data: bytes) -> CoverSource:
    if len(data) > MAX_COVER_BYTES:
        raise ContractError(413, "payload_too_large", "封面不能超过 8 MiB")
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(data), formats=tuple(FORMATS)) as image:
                if image.width * image.height > MAX_PIXELS:
                    raise ValueError("pixel limit")
                image.verify()
            with Image.open(io.BytesIO(data), formats=tuple(FORMATS)) as image:
                safe = (
                    len(data) <= MAX_DISPLAY_BYTES
                    and max(image.size) <= DISPLAY_EDGE
                    and getattr(image, "n_frames", 1) == 1
                    and _safe_container(data, image)
                )
                image.load()
                mime = FORMATS[image.format]
                pixels = _color_pixels(image)
        normalized = _normalized_pixels(pixels, (SIGNATURE_EDGE, SIGNATURE_EDGE))
        tone = round(ImageStat.Stat(normalized.convert("L")).mean[0])
        return CoverSource(pixels, normalized.tobytes(), tone, safe, mime)
    except (
        ValueError,
        OSError,
        SyntaxError,
        ImageCms.PyCMSError,
        Image.DecompressionBombError,
        Image.DecompressionBombWarning,
    ):
        raise ContractError(
            415,
            "unsupported_media_type",
            "封面须为可解码的 PNG、JPEG 或 WebP，最多 2400 万像素",
        ) from None


def _difference_stats(image: Image.Image) -> tuple[float, float]:
    histogram = image.histogram()
    count = image.width * image.height * 4
    average = sum((i % 256) * value for i, value in enumerate(histogram)) / count
    above_ten = sum(value for i, value in enumerate(histogram) if i % 256 > 10)
    return average, above_ten / count


def signatures_agree(left: bytes, right: bytes) -> bool:
    """Screen candidates with registered color and alpha signatures."""
    size = (SIGNATURE_EDGE, SIGNATURE_EDGE)
    first = Image.frombytes("RGBA", size, left)
    second = Image.frombytes("RGBA", size, right)
    # A nearly flat image provides insufficient evidence for a cross-file match.
    if min(max(ImageStat.Stat(image).stddev[:3]) for image in (first, second)) < 12:
        return False
    difference = ImageChops.difference(first, second)
    mean, share = _difference_stats(difference)
    if mean > 2.5 or share > 0.035:
        return False
    for y in range(0, SIGNATURE_EDGE, 16):
        for x in range(0, SIGNATURE_EDGE, 16):
            mean, share = _difference_stats(difference.crop((x, y, x + 16, y + 16)))
            if mean > 5.0 or share > 0.16:
                return False
    return True


def detail_agrees(left: Image.Image, right: Image.Image) -> bool:
    """Reject differences confined to a small region such as one printed digit."""
    width = min(left.width, right.width)
    height = min(left.height, right.height)
    scale = min(1, DISPLAY_EDGE / max(width, height))
    size = (max(1, round(width * scale)), max(1, round(height * scale)))
    noise_filter = ImageFilter.GaussianBlur(0.7)
    left_detail = _normalized_pixels(left, size).filter(noise_filter)
    right_detail = _normalized_pixels(right, size).filter(noise_filter)
    difference = ImageChops.difference(left_detail, right_detail)
    # A 5×5 local mean suppresses isolated codec noise. Use the worst patch
    # and channel so a localized edit cannot be averaged into the whole image.
    local = difference.filter(ImageFilter.BoxBlur(2))
    return max(peak for _, peak in local.getextrema()) <= 24


def display_image(source: CoverSource, *, prefer_lossless: bool) -> tuple[bytes, str]:
    edge = DISPLAY_EDGE
    if prefer_lossless and max(source.pixels.size) <= edge:
        output = io.BytesIO()
        source.pixels.save(output, format="WEBP", lossless=True, method=4)
        if output.tell() <= MAX_DISPLAY_BYTES:
            return output.getvalue(), "image/webp"
    while True:
        longest = max(source.pixels.size)
        pixels = source.pixels
        if longest > edge:
            size = tuple(max(1, round(side * edge / longest)) for side in pixels.size)
            pixels = pixels.resize(size, Image.Resampling.LANCZOS)
        for quality in (88, 82, 74):
            output = io.BytesIO()
            pixels.save(output, format="WEBP", quality=quality, method=4)
            if output.tell() <= MAX_DISPLAY_BYTES:
                return output.getvalue(), "image/webp"
        # Downsample from the source to avoid stacking resize or codec artifacts.
        edge = max(pixels.size) * 4 // 5
