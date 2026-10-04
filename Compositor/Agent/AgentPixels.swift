import CoreGraphics
import Foundation

/// An image's pixels as straight (not premultiplied) sRGB RGBA bytes, rows from the top.
nonisolated struct AgentBitmap: @unchecked Sendable {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    init(_ image: CGImage, width: Int? = nil, height: Int? = nil) throws {
        let width = width ?? image.width, height = height ?? image.height
        guard width > 0, height > 0 else { throw ExportError.render }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ExportError.render }
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Int(bytes[index + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in 0..<3 { bytes[index + channel] = UInt8(min(255, (Int(bytes[index + channel]) * 255 + alpha / 2) / alpha)) }
        }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// One byte per pixel: a grayscale image's values, such as a selection's coverage.
    static func gray(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ExportError.render }
        return bytes
    }

    func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let index = (y * width + x) * 4
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]), Int(bytes[index + 3]))
    }

    /// The average over the square `radius` pixels around (x, y), weighted by alpha so transparent pixels don't
    /// darken it. Nil outside the image.
    func average(x: Int, y: Int, radius: Int) -> (r: Double, g: Double, b: Double, a: Double)? {
        guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0, count = 0.0
        for row in max(0, y - radius)...min(height - 1, y + radius) {
            for column in max(0, x - radius)...min(width - 1, x + radius) {
                let p = pixel(column, row)
                let weight = Double(p.a)
                r += Double(p.r) * weight; g += Double(p.g) * weight; b += Double(p.b) * weight
                a += weight
                count += 1
            }
        }
        guard a > 0 else { return (0, 0, 0, 0) }
        return (r / a, g / a, b / a, a / count / 255)
    }
}

/// The measurements the perception tools report, worked out off the main thread.
nonisolated enum AgentPixels {
    /// Most pixels the statistics read; a bigger picture is averaged down to this first.
    static let statisticsPixels = 4_000_000
    /// Sharpness and noise need pixels as they are, so they read at most this square from the middle at full size.
    static let detailSide = 2048

    static func luma(_ r: Int, _ g: Int, _ b: Int) -> Int { (2126 * r + 7152 * g + 722 * b + 5000) / 10_000 }

    /// The opaque part of `image`, in its pixels, found from its alpha; nil when it's fully transparent.
    static func contentBounds(_ image: CGImage) throws -> CGRect? {
        let scale = min(1, 4096 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded(.up))), height = max(1, Int((CGFloat(image.height) * scale).rounded(.up)))
        var alpha = [UInt8](repeating: 0, count: width * height)
        let drawn = alpha.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: nil, bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ExportError.render }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where alpha[row + x] > 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let x0 = (CGFloat(minX) / scale).rounded(.down), y0 = (CGFloat(minY) / scale).rounded(.down)
        let x1 = min(CGFloat(image.width), (CGFloat(maxX + 1) / scale).rounded(.up))
        let y1 = min(CGFloat(image.height), (CGFloat(maxY + 1) / scale).rounded(.up))
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Tone, color, clipping, sharpness and noise of `image`, counting only pixels that are mostly opaque and, with
    /// `coverage` (grayscale, the image's size), mostly selected.
    static func analyze(_ image: CGImage, coverage: CGImage?, bins: Int) throws -> JSONObject {
        let scale = min(1, (Double(statisticsPixels) / Double(image.width * image.height)).squareRoot())
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        let bitmap = try AgentBitmap(image, width: width, height: height)
        let mask = try coverage.map { try AgentBitmap.gray($0, width: width, height: height) }
        var red = [Int](repeating: 0, count: 256), green = red, blue = red, light = red
        var counted = 0, opaque = 0, highlights = 0, shadows = 0
        var clipped = [0, 0, 0]
        var saturation = 0.0
        var rg = 0.0, yb = 0.0, rg2 = 0.0, yb2 = 0.0
        var midR = 0.0, midG = 0.0, midB = 0.0, mid = 0.0
        var palette = [Int](repeating: 0, count: 4096)
        for index in 0..<(width * height) {
            let offset = index * 4
            let a = Int(bitmap.bytes[offset + 3])
            if a > 0 { opaque += 1 }
            guard a >= 128, mask.map({ $0[index] >= 128 }) ?? true else { continue }
            let r = Int(bitmap.bytes[offset]), g = Int(bitmap.bytes[offset + 1]), b = Int(bitmap.bytes[offset + 2])
            let l = luma(r, g, b)
            counted += 1
            red[r] += 1; green[g] += 1; blue[b] += 1; light[l] += 1
            let high = max(r, g, b), low = min(r, g, b)
            if high >= 254 { highlights += 1 }
            if high <= 2 { shadows += 1 }
            if r >= 254 { clipped[0] += 1 }
            if g >= 254 { clipped[1] += 1 }
            if b >= 254 { clipped[2] += 1 }
            if high > 0 { saturation += Double(high - low) / Double(high) }
            let dRG = Double(r - g), dYB = Double(r + g) / 2 - Double(b)
            rg += dRG; yb += dYB; rg2 += dRG * dRG; yb2 += dYB * dYB
            if (40...215).contains(l) { midR += Double(r); midG += Double(g); midB += Double(b); mid += 1 }
            palette[(r >> 4) << 8 | (g >> 4) << 4 | b >> 4] += 1
        }
        var result: JSONObject = [
            "analyzed_width": width, "analyzed_height": height, "scale": scale,
            "opaque_fraction": Double(opaque) / Double(width * height),
            "pixels_counted": counted,
        ]
        guard counted > 0 else {
            result["note"] = "No opaque pixels to measure here."
            return result
        }
        let total = Double(counted)
        func summary(_ histogram: [Int]) -> JSONObject {
            var sum = 0.0, squares = 0.0
            for (value, count) in histogram.enumerated() { sum += Double(value * count); squares += Double(value * value * count) }
            let mean = sum / total
            func percentile(_ p: Double) -> Int {
                let target = Int((total * p).rounded(.up))
                var running = 0
                for (value, count) in histogram.enumerated() {
                    running += count
                    if running >= max(1, target) { return value }
                }
                return 255
            }
            let grouped = stride(from: 0, to: 256, by: 256 / bins).map { start in
                (histogram[start..<min(256, start + 256 / bins)].reduce(0, +) * 10_000 / counted)
            }.map { Double($0) / 100 }
            return ["mean": mean, "std": max(0, squares / total - mean * mean).squareRoot(),
                    "p1": percentile(0.01), "p5": percentile(0.05), "median": percentile(0.5),
                    "p95": percentile(0.95), "p99": percentile(0.99), "histogram_percent": grouped]
        }
        let lightSummary = summary(light)
        result["luminance"] = lightSummary
        result["red"] = summary(red)
        result["green"] = summary(green)
        result["blue"] = summary(blue)
        result["clipping"] = ["highlights_fraction": Double(highlights) / total, "shadows_fraction": Double(shadows) / total,
                              "red_fraction": Double(clipped[0]) / total, "green_fraction": Double(clipped[1]) / total,
                              "blue_fraction": Double(clipped[2]) / total]
        let meanRG = rg / total, meanYB = yb / total
        let colorfulness = (max(0, rg2 / total - meanRG * meanRG) + max(0, yb2 / total - meanYB * meanYB)).squareRoot()
            + 0.3 * (meanRG * meanRG + meanYB * meanYB).squareRoot()
        result["color"] = ["mean_saturation": saturation / total, "colorfulness": colorfulness]
        var hints: [String] = []
        if mid > 0 {
            let warmth = (midR - midB) / mid, tint = (midG - (midR + midB) / 2) / mid
            var cast: [String] = []
            if warmth > 8 { cast.append("warm (yellow/orange)") } else if warmth < -8 { cast.append("cool (blue)") }
            if tint > 6 { cast.append("green") } else if tint < -6 { cast.append("magenta") }
            result["cast"] = ["red_minus_blue": warmth, "green_minus_magenta": tint, "midtone_pixels": Int(mid),
                              "verdict": cast.isEmpty ? "neutral" : cast.joined(separator: " and ")]
            if !cast.isEmpty { hints.append("Midtones lean \(cast.joined(separator: " and ")); if that isn’t intended, a white-balance or color correction would neutralize it.") }
        }
        let median = lightSummary["median"] as? Int ?? 128, p99 = lightSummary["p99"] as? Int ?? 255, p1 = lightSummary["p1"] as? Int ?? 0
        let std = lightSummary["std"] as? Double ?? 0
        if Double(highlights) / total > 0.02 { hints.append("\(percent(Double(highlights) / total)) of pixels are clipped to white; highlight detail there is gone.") }
        if Double(shadows) / total > 0.02 { hints.append("\(percent(Double(shadows) / total)) of pixels are crushed to black.") }
        if median < 70 && p99 < 220 { hints.append("Dark overall (median luminance \(median)); it may be underexposed.") }
        if median > 190 && p1 > 60 { hints.append("Bright overall (median luminance \(median)); it may be overexposed.") }
        if p99 - p1 < 140 || std < 35 { hints.append("Low contrast: luminance spans \(p1)–\(p99) of 0–255.") }
        if colorfulness < 15 && saturation / total > 0.02 { hints.append("Muted colors (colorfulness \(Int(colorfulness)); above 40 reads as colorful).") }

        // The most common colors, merged where they're close.
        var colors: [(r: Int, g: Int, b: Int, count: Int)] = []
        for (bin, count) in palette.enumerated().filter({ $0.element > 0 }).sorted(by: { $0.element > $1.element }) {
            let r = (bin >> 8) * 16 + 8, g = ((bin >> 4) & 15) * 16 + 8, b = (bin & 15) * 16 + 8
            if let near = colors.firstIndex(where: { abs($0.r - r) + abs($0.g - g) + abs($0.b - b) < 72 }) {
                colors[near].count += count
            } else if colors.count < 8 {
                colors.append((r, g, b, count))
            }
        }
        result["palette"] = colors.sorted { $0.count > $1.count }.prefix(6).map {
            ["color": AgentColor.hex(red: CGFloat($0.r) / 255, green: CGFloat($0.g) / 255, blue: CGFloat($0.b) / 255),
             "fraction": Double($0.count) / total] as JSONObject
        }
        let detail = try detail(image, coverage: coverage)
        result["detail"] = detail.json
        if let sharpness = detail.sharpness, sharpness < 60 { hints.append("Soft or blurry (sharpness \(Int(sharpness)); crisp photos usually measure over 150).") }
        if let noise = detail.noise, noise > 6 { hints.append("Visible noise (about \(String(format: "%.1f", noise)) levels of 255); a noise reduction filter may help.") }
        result["hints"] = hints
        return result
    }

    private static func percent(_ fraction: Double) -> String { String(format: "%.1f%%", fraction * 100) }

    /// Sharpness (variance of the Laplacian) and noise (Immerkær's estimate of its standard deviation), both in levels of
    /// 255, over at most `detailSide` square from the middle of `image` at full size.
    private static func detail(_ image: CGImage, coverage: CGImage?) throws -> (json: JSONObject, sharpness: Double?, noise: Double?) {
        let side = detailSide
        let crop = CGRect(x: max(0, (image.width - side) / 2), y: max(0, (image.height - side) / 2),
                          width: min(side, image.width), height: min(side, image.height))
        guard crop.width >= 3, crop.height >= 3, let part = image.cropping(to: crop) else { return ([:], nil, nil) }
        let width = part.width, height = part.height
        let bitmap = try AgentBitmap(part)
        let mask = try coverage.flatMap { $0.cropping(to: crop) }.map { try AgentBitmap.gray($0, width: width, height: height) }
        var gray = [Int](repeating: -1, count: width * height)
        for index in 0..<(width * height) where bitmap.bytes[index * 4 + 3] >= 250 && (mask.map { $0[index] >= 250 } ?? true) {
            gray[index] = luma(Int(bitmap.bytes[index * 4]), Int(bitmap.bytes[index * 4 + 1]), Int(bitmap.bytes[index * 4 + 2]))
        }
        var laplacian = 0.0, laplacian2 = 0.0, noise = 0.0, count = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let c = gray[i], n = gray[i - width], s = gray[i + width], w = gray[i - 1], e = gray[i + 1]
                let nw = gray[i - width - 1], ne = gray[i - width + 1], sw = gray[i + width - 1], se = gray[i + width + 1]
                guard c >= 0, n >= 0, s >= 0, w >= 0, e >= 0, nw >= 0, ne >= 0, sw >= 0, se >= 0 else { continue }
                let l = Double(n + s + w + e - 4 * c)
                laplacian += l; laplacian2 += l * l
                noise += Double(abs(nw - 2 * n + ne - 2 * w + 4 * c - 2 * e + sw - 2 * s + se))
                count += 1
            }
        }
        guard count > 0 else { return ([:], nil, nil) }
        let mean = laplacian / count
        let sharpness = laplacian2 / count - mean * mean
        let sigma = noise / count * (Double.pi / 2).squareRoot() / 6
        return (["sharpness": sharpness, "noise": sigma,
                 "measured": ["x": crop.minX, "y": crop.minY, "width": crop.width, "height": crop.height] as JSONObject],
                sharpness, sigma)
    }

    /// Where and how much `after` differs from `before` (the same size): the fraction of pixels whose largest channel
    /// difference is over `threshold` (0…1), their bounds, and a map of them over a faded `after`.
    static func difference(_ before: CGImage, _ after: CGImage, threshold: Double) throws -> (json: JSONObject, map: CGImage) {
        let scale = min(1, (Double(4 * statisticsPixels) / Double(after.width * after.height)).squareRoot())
        let width = max(1, Int(Double(after.width) * scale)), height = max(1, Int(Double(after.height) * scale))
        let old = try AgentBitmap(before, width: width, height: height)
        var new = try AgentBitmap(after, width: width, height: height)
        let limit = Int((threshold * 255).rounded())
        var changed = 0, sum = 0.0, largest = 0
        var minX = width, minY = height, maxX = -1, maxY = -1
        var lumaBefore = 0.0, lumaAfter = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let a = old.pixel(x, y), b = new.pixel(x, y)
                // Compared as drawn over black, so a color change under full transparency doesn't count.
                func over(_ value: Int, _ alpha: Int) -> Int { value * alpha / 255 }
                let dr = abs(over(a.r, a.a) - over(b.r, b.a)), dg = abs(over(a.g, a.a) - over(b.g, b.a))
                let db = abs(over(a.b, a.a) - over(b.b, b.a)), da = abs(a.a - b.a)
                let delta = max(dr, dg, db, da)
                sum += Double(dr + dg + db + da) / 4
                largest = max(largest, delta)
                lumaBefore += Double(luma(over(a.r, a.a), over(a.g, a.a), over(a.b, a.a)))
                lumaAfter += Double(luma(over(b.r, b.a), over(b.g, b.a), over(b.b, b.a)))
                let index = (y * width + x) * 4
                let faded = UInt8(60 + luma(b.r, b.g, b.b) * b.a / 255 * 80 / 255)
                if delta > limit {
                    changed += 1
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    let strength = min(255, 120 + delta * 2)
                    new.bytes[index] = UInt8(strength); new.bytes[index + 1] = faded / 3; new.bytes[index + 2] = faded / 3
                } else {
                    new.bytes[index] = faded; new.bytes[index + 1] = faded; new.bytes[index + 2] = faded
                }
                new.bytes[index + 3] = 255
            }
        }
        let pixels = Double(width * height)
        var json: JSONObject = ["changed_fraction": Double(changed) / pixels, "mean_difference": sum / pixels / 255,
                                "largest_difference": Double(largest) / 255, "threshold": threshold,
                                "mean_luminance_before": lumaBefore / pixels, "mean_luminance_after": lumaAfter / pixels]
        if maxX >= 0 {
            json["changed_bounds"] = ["x": (Double(minX) / scale).rounded(.down), "y": (Double(minY) / scale).rounded(.down),
                                      "width": (Double(maxX - minX + 1) / scale).rounded(.up), "height": (Double(maxY - minY + 1) / scale).rounded(.up)]
        }
        if scale < 1 { json["measured_scale"] = scale }
        let map = try new.bytes.withUnsafeMutableBytes { buffer -> CGImage in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = context.makeImage() else { throw ExportError.render }
            return image
        }
        return (json, map)
    }
}

/// Lets a result built off the main thread come back to it.
nonisolated struct AgentSendable<Value>: @unchecked Sendable {
    let value: Value
}
