"""Profile cover wire fields shared by the server and the guarded MCP adapter."""

from typing import Literal

from pydantic import Field

from .profile import StrictRequest

UPLOAD_PATH = "/me/cover"
READ_PATH = "/covers/{account}"
DEFAULT_HEADER = "X-BB-Cover-Default"
MAX_COVER_BYTES = 8 * 1024 * 1024
MAX_COVER_BASE64 = 4 * ((MAX_COVER_BYTES + 2) // 3)
MAX_DISPLAY_BYTES = 512 * 1024
MAX_DISPLAY_BASE64 = 4 * ((MAX_DISPLAY_BYTES + 2) // 3)
MIME_TYPES = ("image/png", "image/jpeg", "image/webp")
CoverMime = Literal["image/png", "image/jpeg", "image/webp"]


class CoverUpload(StrictRequest):
    base64: str = Field(
        min_length=1,
        max_length=MAX_COVER_BASE64,
        repr=False,
        description="Raw padded standard base64 of a PNG, JPEG or WebP. At most 8 MiB decoded.",
    )


class CoverResponse(StrictRequest):
    cover_url: str = Field(pattern=r"^/covers/[1-9][0-9]{7}$")
    cover_version: str = Field(pattern=r"^sha256-[0-9a-f]{64}$")


class CoverImageResponse(CoverResponse):
    account: str = Field(pattern=r"^[1-9][0-9]{7}$")
    mime_type: CoverMime
    data: str = Field(min_length=1, max_length=MAX_DISPLAY_BASE64, repr=False)
    is_default: bool
