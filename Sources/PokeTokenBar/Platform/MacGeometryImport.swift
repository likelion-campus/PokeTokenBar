#if canImport(CoreGraphics)
// The Mac pre-check (scripts/shared-check.sh) builds the shared set with no file importing CoreGraphics, and on the
// Mac `Foundation` alone does not expose CGRect.minX / midX, CGVector.zero or their Equatable conformances. The
// swift-corelibs Foundation on Windows defines them itself. This import makes them visible module-wide on the Mac.
// SharedSourcesScanTests allows exactly this file to import CoreGraphics.
import CoreGraphics
#endif
