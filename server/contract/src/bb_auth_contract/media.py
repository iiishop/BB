"""Media retrieval contract shared by the HTTP implementation and consumers."""

from typing import Literal

MediaVariant = Literal["original", "thumb"]
THUMB_MAX_EDGE = 512
THUMB_MAX_BYTES = 64 * 1024
THUMB_MIME = "image/jpeg"
