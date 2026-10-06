import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 跨平台图片处理工具。
///
/// Shared 层不允许出现 NSImage / UIImage（它们分属 AppKit / UIKit），
/// 因此这里统一用 Data + ImageIO + CoreGraphics 处理位图：
/// 这三套框架在 macOS 与 iOS 上都可用，行为也一致。
enum PlatformImageCodec {

    /// 读取图片数据的像素尺寸。解码失败返回 nil。
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        let width = (properties[kCGImagePropertyPixelWidth] as? CGFloat) ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? CGFloat) ?? 0
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// 按最长边约束等比缩放。
    ///
    /// 只在确实需要缩小时才重采样（`scale >= 1` 原样返回），
    /// 避免为了"统一处理"把已经合规的图重新编码一次、损失画质。
    static func resize(_ data: Data, maxEdge: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return data }

        let originalWidth = CGFloat(image.width)
        let originalHeight = CGFloat(image.height)
        let longestEdge = max(originalWidth, originalHeight)
        guard longestEdge > CGFloat(maxEdge) else { return data }

        let scale = CGFloat(maxEdge) / longestEdge
        let targetWidth = max(1, Int((originalWidth * scale).rounded()))
        let targetHeight = max(1, Int((originalHeight * scale).rounded()))

        guard let resized = resizeCGImage(image, width: targetWidth, height: targetHeight) else { return data }
        return encodeJPEG(resized, quality: 0.9)
    }

    /// 统一转成 JPEG。`quality` 会被夹在 0.1...1.0，避免调用方传入越界值导致 ImageIO 报错。
    static func encodeJPEG(_ data: Data, quality: Double) -> (Data, String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let jpeg = encodeJPEG(image, quality: quality)
        return (jpeg, "image/jpeg")
    }

    static func encodeJPEG(_ image: CGImage, quality: Double) -> Data {
        let clampedQuality = max(0.1, min(1.0, quality))
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return Data() }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: clampedQuality] as CFDictionary
        )
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    /// 直接重采样到目标尺寸。
    private static func resizeCGImage(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// 面向视觉模型的图片编码：等比缩放到 `maxEdge` 以内并转 JPEG。
    ///
    /// - Returns: (data, mediaType)。输入无法解码时返回 nil，调用方应据此降级。
    static func encodeForVision(_ data: Data, quality: Double, maxEdge: Int) -> (Data, String)? {
        let clampedEdge = max(64, min(4096, maxEdge))
        guard let scaled = resize(data, maxEdge: clampedEdge) else { return nil }
        return encodeJPEG(scaled, quality: quality)
    }
}
