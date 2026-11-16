import AppKit
import CoreImage
import ImageIO
import YAMECore
import UniformTypeIdentifiers

/// How a non-square picture becomes a square cover.
enum CoverFit: String, CaseIterable, Identifiable {
    case crop, blur, white, black

    var id: String { rawValue }
    var label: String {
        switch self {
        case .crop: return "Crop"
        case .blur: return "Fit · Blur"
        case .white: return "Fit · White"
        case .black: return "Fit · Black"
        }
    }
}

/// Turns any picture into a car-friendly square, baseline JPEG.
enum CoverProcessor {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func cgImage(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// An image from the clipboard (copied image, screenshot, or a copied image file).
    static func imageFromPasteboard(_ pb: NSPasteboard = .general) -> CGImage? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL],
           let url = urls.first, let data = try? Data(contentsOf: url), let img = cgImage(from: data) {
            return img
        }
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], let first = images.first {
            return cgImage(from: first)
        }
        return nil
    }

    static func isSquare(_ img: CGImage) -> Bool {
        let w = Double(img.width), h = Double(img.height)
        return abs(w - h) / max(w, h) < 0.02
    }

    /// Removes black (or near-black) letterbox bars, like the ones on YouTube thumbnails.
    static func trimmingDarkBars(_ img: CGImage, threshold: Int = 28) -> CGImage {
        let w = img.width, h = img.height
        guard w > 8, h > 8,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let buf = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return img }

        func rowIsDark(_ y: Int) -> Bool {
            var bright = 0
            for x in stride(from: 0, to: w, by: 2) {
                let p = (y * w + x) * 4
                if max(buf[p], buf[p + 1], buf[p + 2]) > threshold { bright += 1; if bright > w / 100 + 1 { return false } }
            }
            return true
        }
        func colIsDark(_ x: Int, _ top: Int, _ bottom: Int) -> Bool {
            var bright = 0
            for y in stride(from: top, to: bottom, by: 2) {
                let p = (y * w + x) * 4
                if max(buf[p], buf[p + 1], buf[p + 2]) > threshold { bright += 1; if bright > h / 100 + 1 { return false } }
            }
            return true
        }
        // Buffer rows run top to bottom.
        var top = 0, bottom = h
        while top < h / 3, rowIsDark(top) { top += 1 }
        while bottom > h * 2 / 3, rowIsDark(bottom - 1) { bottom -= 1 }
        var left = 0, right = w
        while left < w / 3, colIsDark(left, top, bottom) { left += 1 }
        while right > w * 2 / 3, colIsDark(right - 1, top, bottom) { right -= 1 }
        guard top > 0 || left > 0 || bottom < h || right < w else { return img }
        return img.cropping(to: CGRect(x: left, y: top, width: right - left, height: bottom - top)) ?? img
    }

    /// Renders the square cover.
    /// - Parameter offset: -1…1 position for cropping (left/top … right/bottom).
    static func render(_ src: CGImage, fit: CoverFit, offset: Double, size: Int) -> CGImage? {
        let s = CGFloat(size)
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let w = CGFloat(src.width), h = CGFloat(src.height)

        func fillRect(offset: Double) -> CGRect {
            let scale = s / min(w, h)
            let dw = w * scale, dh = h * scale
            let ex = dw - s, ey = dh - s
            let o = CGFloat(max(-1, min(1, offset)))
            // CoreGraphics' origin is bottom-left: offset -1 shows the top / left edge.
            return CGRect(x: -ex * (o + 1) / 2, y: -ey * (1 - o) / 2, width: dw, height: dh)
        }

        switch fit {
        case .crop:
            ctx.draw(src, in: fillRect(offset: offset))
            return ctx.makeImage()
        case .white, .black:
            ctx.setFillColor(fit == .white ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        case .blur:
            ctx.draw(src, in: fillRect(offset: 0))
            if let filled = ctx.makeImage() {
                let ci = CIImage(cgImage: filled).clampedToExtent()
                    .applyingGaussianBlur(sigma: Double(s) * 0.045)
                    .cropped(to: CGRect(x: 0, y: 0, width: s, height: s))
                if let blurred = ciContext.createCGImage(ci, from: CGRect(x: 0, y: 0, width: s, height: s)) {
                    ctx.draw(blurred, in: CGRect(x: 0, y: 0, width: s, height: s))
                    ctx.setFillColor(CGColor(gray: 0, alpha: 0.12))
                    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
                }
            }
        }
        let scale = s / max(w, h)
        let dw = w * scale, dh = h * scale
        ctx.draw(src, in: CGRect(x: (s - dw) / 2, y: (s - dh) / 2, width: dw, height: dh))
        return ctx.makeImage()
    }

    /// Baseline (non-progressive) JPEG — the format car stereos read reliably.
    static func jpegData(_ img: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: false],
        ]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Fetches the best available YouTube thumbnail for a link.
    static func youtubeThumbnail(for link: String) async throws -> CGImage {
        guard let id = YouTube.videoID(from: link) else { throw CoverError.badLink }
        for url in YouTube.thumbnailURLs(for: id) {
            guard let result = try? await URLSession.shared.data(from: url),
                  (result.1 as? HTTPURLResponse)?.statusCode == 200,
                  let img = cgImage(from: result.0), img.width > 200 else { continue }
            return img
        }
        throw CoverError.notFound
    }

    enum CoverError: LocalizedError {
        case badLink, notFound
        var errorDescription: String? {
            switch self {
            case .badLink: return "That doesn’t look like a YouTube link."
            case .notFound: return "Couldn’t download a thumbnail for that video."
            }
        }
    }
}
