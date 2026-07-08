//! Metadata-only logging for gjc-relay.

/// Metadata-only logging. NEVER receives headers or bodies.
pub(crate) fn log_meta(event: &str, msg: &str) {
    println!("gjc-relay [{event}] {msg}");
}
