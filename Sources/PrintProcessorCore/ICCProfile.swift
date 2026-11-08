import Foundation
import CoreGraphics
import Compression

/// Shared sRGB ICC-profile helpers. ImageIO does not expose a way to force an
/// ICC profile into a PNG (it writes an `sRGB` rendering-intent chunk instead of
/// `iCCP`) or into a JPEG (it writes a minimal Exif APP1 and no ICC APP2), so
/// these small byte-level utilities embed the real sRGB IEC 61966-2.1 profile
/// into the containers that `cwebp` and colour-managed readers understand.
enum ICCProfile {
    /// The sRGB IEC 61966-2.1 ICC profile bytes (nil when unavailable).
    static func sRGBData() -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return space.copyICCData() as Data?
    }

    // MARK: - zlib (RFC 1950) via the Compression framework's raw deflate

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        let mod: UInt32 = 65521
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % mod
            b = (b + a) % mod
        }
        return (b << 16) | a
    }

    /// Deflate `data` into a zlib (RFC 1950) stream. `COMPRESSION_ZLIB` emits
    /// raw deflate, so a 2-byte header and Adler-32 trailer are added by hand.
    static func zlibCompress(_ data: Data) -> Data? {
        let src = [UInt8](data)
        let dstSize = src.count + src.count / 16 + 64 + 3
        var dst = [UInt8](repeating: 0, count: dstSize)
        let written = dst.withUnsafeMutableBufferPointer { buf -> Int in
            src.withUnsafeBufferPointer { srcBuf -> Int in
                guard let s = srcBuf.baseAddress, let d = buf.baseAddress else { return 0 }
                return compression_encode_buffer(d, buf.count, s, srcBuf.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        var out: [UInt8] = [0x78, 0x9C]
        out.append(contentsOf: dst[0..<written])
        let sum = adler32(src)
        out.append(UInt8((sum >> 24) & 0xFF))
        out.append(UInt8((sum >> 16) & 0xFF))
        out.append(UInt8((sum >> 8) & 0xFF))
        out.append(UInt8(sum & 0xFF))
        return Data(out)
    }

    // MARK: - CRC-32 (PNG chunks)

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1 != 0) ? ((crc >> 1) ^ 0xEDB8_8320) : (crc >> 1)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: - PNG iCCP injection

    /// Insert an iCCP chunk (sRGB profile) immediately after the IHDR chunk of
    /// an existing PNG file, rewriting it in place. All other chunks (including
    /// the ImageIO-added eXIf) are left untouched; `cwebp -metadata icc` reads
    /// only the iCCP chunk and drops everything else.
    @discardableResult
    static func injectICC(intoPNGAt url: URL, icc: Data) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        var bytes = [UInt8](data)
        guard bytes.count > 33, bytes[0] == 0x89, bytes[1] == 0x50 else { return false }
        let ihdrLen = (Int(bytes[8]) << 24) | (Int(bytes[9]) << 16) | (Int(bytes[10]) << 8) | Int(bytes[11])
        let insertAt = 8 + 12 + ihdrLen
        guard insertAt <= bytes.count else { return false }
        guard let compressed = zlibCompress(icc) else { return false }

        var chunkData: [UInt8] = Array("ICC Profile\0".utf8)
        chunkData.append(0x00)  // compression method: deflate
        chunkData.append(contentsOf: compressed)

        var typeAndData: [UInt8] = Array("iCCP".utf8)
        typeAndData.append(contentsOf: chunkData)
        let crc = crc32(typeAndData)

        var chunk: [UInt8] = []
        let len = chunkData.count
        chunk.append(UInt8((len >> 24) & 0xFF))
        chunk.append(UInt8((len >> 16) & 0xFF))
        chunk.append(UInt8((len >> 8) & 0xFF))
        chunk.append(UInt8(len & 0xFF))
        chunk.append(contentsOf: typeAndData)
        chunk.append(UInt8((crc >> 24) & 0xFF))
        chunk.append(UInt8((crc >> 16) & 0xFF))
        chunk.append(UInt8((crc >> 8) & 0xFF))
        chunk.append(UInt8(crc & 0xFF))

        bytes.insert(contentsOf: chunk, at: insertAt)
        do {
            try Data(bytes).write(to: url)
            return true
        } catch {
            return false
        }
    }

    // MARK: - JPEG APP2 (ICC_PROFILE) marker

    /// Build the complete APP2 "ICC_PROFILE" marker bytes for a JPEG stream,
    /// split into 1…N segments as required by the ICC embedding convention.
    static func jpegICCAPP2(_ icc: Data) -> [UInt8] {
        let iccBytes = [UInt8](icc)
        let maxData = 65533 - 14  // payload minus "ICC_PROFILE\0" + seq + count
        let total = max(1, (iccBytes.count + maxData - 1) / maxData)
        var out: [UInt8] = []
        for idx in 0..<total {
            let start = idx * maxData
            let end = min(iccBytes.count, start + maxData)
            var payload: [UInt8] = Array("ICC_PROFILE\0".utf8)
            payload.append(UInt8(idx + 1))
            payload.append(UInt8(total))
            payload.append(contentsOf: iccBytes[start..<end])
            let length = payload.count + 2
            out.append(0xFF)
            out.append(0xE2)
            out.append(UInt8((length >> 8) & 0xFF))
            out.append(UInt8(length & 0xFF))
            out.append(contentsOf: payload)
        }
        return out
    }
}
