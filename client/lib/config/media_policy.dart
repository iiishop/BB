/// Client-side media presentation policy (DEA-471).
///
/// The threshold lives here so the list, the viewer and the tests all read one
/// value instead of scattering magic numbers through widget conditions.
library;

/// Images at or below this size are shown from the original bytes directly.
///
/// Anything above it must show a bounded preview first and only fetch the
/// original after an explicit user action. The boundary is inclusive
/// (`<= 100 KiB` is small), per DEA-471 spec v1.
const int mediaDirectOriginalMaxBytes = 100 * 1024;

/// Whether a known media size needs the explicit "原图" action.
bool mediaNeedsExplicitOriginal(int byteSize) =>
    byteSize > mediaDirectOriginalMaxBytes;

/// Whether the size is unknown and must be probed before deciding.
bool mediaNeedsSizeProbe(int? byteSize) => byteSize == null;
