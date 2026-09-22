import Foundation

// `os` (and `os.Logger`) is an Apple-platform module that does not exist
// on Linux. This file is part of the AdapterMac *library* target, which
// does build on Linux, so the import has to be conditional and needs a
// real fallback rather than an empty one. See Package.swift's
// `#if os(macOS)` comment for who actually builds this on Linux today
// (nothing in this repo does).
#if canImport(os)
import os
#endif

/// Error logging for the library target, in one place.
///
/// Extracted from ``NodeRuntime`` when ``MacNode`` needed the same thing
/// (#223): a failed relay command is logged and the subscription
/// survives, so this is now the second caller. Two hand-rolled copies of
/// the `canImport(os)` shim would drift, and the failure mode of drift
/// here is a log line that silently stops appearing - which is the exact
/// class of problem #223 is about.
///
/// Not silently dropped on the non-Apple path: a swallowed error would
/// make a failing node look like an idle one.
func logAdapterError(category: String, _ message: String) {
    #if canImport(os)
    Logger(subsystem: "app.thrw.mac", category: category)
        .error("\(message, privacy: .public)")
    #else
    FileHandle.standardError.write(Data("\(category): \(message)\n".utf8))
    #endif
}

/// The non-error half, for a state change worth recording that isn't a
/// failure - specifically, recovery from one (#236).
///
/// Added because a failure logged once and never followed up reads
/// identically to a failure that is still ongoing. #236 was exactly that:
/// a single `heartbeatPublisher failed: noConnection` line, and no way to
/// tell from the log whether heartbeats had come back. Recording the
/// recovery is what makes the absence of a recovery line meaningful.
func logAdapterInfo(category: String, _ message: String) {
    #if canImport(os)
    Logger(subsystem: "app.thrw.mac", category: category)
        .info("\(message, privacy: .public)")
    #else
    FileHandle.standardError.write(Data("\(category): \(message)\n".utf8))
    #endif
}
