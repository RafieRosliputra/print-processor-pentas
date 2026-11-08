import Foundation
import CoreGraphics
import ImageIO

/// Applies the user's choice after a Photoshop edit of a layer-4 photo.
/// `original` is the edited file currently on disk; `backup` is the pre-edit
/// copy made before Photoshop was opened. Pure file/encode logic (no AppKit) so
/// the Check target can verify the Cancel and Save-as-new-version paths.
public enum PhotoEditSave {
    /// Decode an image file (used to re-encode the edited copy as WebP).
    static func decode(_ path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Save the edited copy as a new numbered WebP beside the original, then
    /// restore the untouched original from the backup. `encode` writes the WebP
    /// (injectable so tests avoid the real cwebp binary). Returns true when the
    /// new WebP was actually written. The original is restored even when the
    /// encode fails — the edited copy never overwrites the source photo.
    @discardableResult
    public static func saveAsNewVersion(
        original: URL,
        backup: URL,
        hadBackup: Bool,
        number: Int,
        encode: (CGImage, URL) -> Bool
    ) -> Bool {
        guard hadBackup else {
            try? FileManager.default.removeItem(at: backup)
            return false
        }
        let out = WebPNumbering.outputURL(psdURL: original, number: number)
        var wrote = false
        if let image = decode(original.path) {
            wrote = encode(image, out)
        }
        try? FileManager.default.removeItem(at: original)
        try? FileManager.default.moveItem(at: backup, to: original)
        return wrote
    }

    /// Replace original: keep the edited copy, drop the backup.
    public static func replaceOriginal(backup: URL) {
        try? FileManager.default.removeItem(at: backup)
    }

    /// Cancel: discard the edited copy and restore the untouched original.
    /// Returns false when no backup existed (nothing to restore).
    @discardableResult
    public static func cancel(original: URL, backup: URL, hadBackup: Bool) -> Bool {
        guard hadBackup else {
            try? FileManager.default.removeItem(at: backup)
            return false
        }
        try? FileManager.default.removeItem(at: original)
        return (try? FileManager.default.moveItem(at: backup, to: original)) != nil
    }
}
