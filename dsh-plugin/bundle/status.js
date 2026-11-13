// Presentation only. These classifications never decide whether binding may retry.
const restrictions = new Set([
  "stale_identity",
  "stale_binding",
  "session_identity_mismatch",
  "recovery_session_required",
  "consumption_gap",
  "idempotency_conflict",
]);
const diagnostics = new Set([
  ...restrictions,
  "unauthenticated",
  "unsupported_version",
  "invalid_response",
  "validation_error",
  "not_found",
  "storage_unavailable",
  "upstream_unavailable",
  "upstream_timeout",
  "payload_too_large",
  "unsupported_media_type",
]);
export function diagnostic(error, fallback) {
  if (diagnostics.has(error?.code)) return error.code;
  const cause = error?.cause;
  if (error?.name === "TypeError" && cause?.message === "bad port")
    return "client_port_restricted";
  if (cause?.code === "ECONNREFUSED") return "client_connection_refused";
  if (
    error?.name === "TimeoutError" ||
    [
      "ETIMEDOUT",
      "UND_ERR_CONNECT_TIMEOUT",
      "UND_ERR_HEADERS_TIMEOUT",
    ].includes(cause?.code)
  )
    return "client_connection_timeout";
  if (error?.name === "TypeError" && error?.message === "fetch failed")
    return "client_connection_failed";
  // Arbitrary upstream errors/messages can contain credentials or stack details.
  return fallback;
}
export function stoppedState(code) {
  if (restrictions.has(code)) return "blocked";
  if (
    [
      "client_port_restricted",
      "client_connection_refused",
      "client_connection_timeout",
      "client_connection_failed",
    ].includes(code)
  )
    return "connection_unavailable";
  if (code === "unauthenticated") return "login_required";
  return "stopped";
}
