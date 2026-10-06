import Foundation
import ImageIO
import CoreText
import CoreGraphics
import UniformTypeIdentifiers

/// 跨平台缩略图生成核心。
///
/// 产出统一是 `Data`（JPEG/PNG 字节），而不是 NSImage / UIImage：
/// PDFKit 与 ImageIO 在 macOS 和 iOS 上都可用，但位图类型是平台专属的。
/// 各平台视图通过 `ThumbnailProvider`（macOS）/ `ThumbnailProvider_iOS`（iOS）
/// 的薄封装把 Data 转成本平台的位图类型。
@MainActor
final class ThumbnailDataProvider {
@MainActor static let shared = ThumbnailDataProvider()

    private var cache: [UUID: Data] = [:]
    private let queue = DispatchQueue(label: "ThumbnailDataProvider.queue", qos: .userInitiated)
    private let cacheLock = NSLock()

    private init() {}

    /// 生成缩略图并在主线程回调。命中缓存时立即回调。
    func thumbnailData(
        for material: StudyMaterial,
        size: CGSize = CGSize(width: 64, height: 64),
        completion: @escaping (Data?) -> Void
    ) {
        let cacheKey = material.id
        cacheLock.lock()
        let cached = cache[cacheKey]
        cacheLock.unlock()

        if let cached {
            completion(cached)
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            let data = self.produceData(for: material, size: size)

            if let data {
                self.cacheLock.lock()
                self.cache[cacheKey] = data
                self.cacheLock.unlock()
            }

            DispatchQueue.main.async {
                completion(data)
            }
        }
    }

    /// 同步生成（供已经确认在后台线程的场景使用）。
    func thumbnailDataSynchronously(for material: StudyMaterial, size: CGSize = CGSize(width: 64, height: 64)) -> Data? {
        cacheLock.lock()
        let cached = cache[material.id]
        cacheLock.unlock()
        if let cached { return cached }

        let data = produceData(for: material, size: size)
        if let data {
            cacheLock.lock()
            cache[material.id] = data
            cacheLock.unlock()
        }
        return data
    }

    func removeCache(for materialID: UUID) {
        cacheLock.lock()
        cache.removeValue(forKey: materialID)
        cacheLock.unlock()
    }

    func clearCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    // MARK: - 生成

    private func produceData(for material: StudyMaterial, size: CGSize) -> Data? {
        guard let localURL = material.localURL else { return nil }

        switch material.type {
        case .image:
            return downsampleImage(at: localURL, maxPixel: max(size.width, size.height))
        case .pdf:
            return pdfThumbnail(at: localURL, size: size)
        default:
            // 其它类型回落到按扩展名合成的占位图（见 placeholderData）。
            return placeholderData(for: material)
        }
    }

    /// 图片缩略：直接用 ImageIO 的 thumbnail 路径取缩略图，
    /// 避免把整张大图解码进内存再缩放（4K 照片会瞬间吃掉几十 MB）。
    private func downsampleImage(at url: URL, maxPixel: CGFloat) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return PlatformImageCodec.encodeJPEG(thumbnail, quality: 0.85)
    }

    /// PDF 首页缩略图。
    ///
    /// 不走 `PDFPage.thumbnail(of:for:)`：那个方法在 macOS 返回 NSImage、
    /// 在 iOS 返回 UIImage，签名相同但类型不同，无法写进 Shared。
    /// 改用 CoreGraphics 的 CGPDFDocument 自己渲染，两端都是 CGImage。
    private func pdfThumbnail(at url: URL, size: CGSize) -> Data? {
        guard let document = CGPDFDocument(url as CFURL),
              let page = document.page(at: 1)
        else { return nil }

        let pageBox = page.getBoxRect(.mediaBox)
        guard pageBox.width > 0, pageBox.height > 0 else { return nil }

        // 等比缩放到目标框内，并按页面方向补齐宽高比。
        let widthScale = size.width / pageBox.width
        let heightScale = size.height / pageBox.height
        let scale = min(widthScale, heightScale)

        let targetWidth = max(1, Int((pageBox.width * scale).rounded()))
        let targetHeight = max(1, Int((pageBox.height * scale).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // PDF 原点在左下角且尺寸是 point，先缩放坐标系再平移，
        // 否则页面会渲染到画布外侧得到空白图。
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        context.scaleBy(x: scale, y: scale)
        context.drawPDFPage(page)

        guard let image = context.makeImage() else { return nil }
        return PlatformImageCodec.encodeJPEG(image, quality: 0.85)
    }

    /// 没有可预览内容时，按资料类型画一个纯色占位缩略图。
    ///
    /// 之前 macOS 版用 `NSWorkspace.shared.icon(forFileType:)`，那是 AppKit 专属 API，
    /// iOS 上不存在。改为在 CoreGraphics 上画纯色块 + CoreText 渲染类型首字母，
    /// 两端行为完全一致，也不会因为系统图标风格变化而影响列表外观。
    private func placeholderData(for material: StudyMaterial) -> Data? {
        let size = CGSize(width: 128, height: 128)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(placeholderColor(for: material.type))
        context.fill(CGRect(origin: .zero, size: size))

        if let glyphImage = renderGlyph(for: material.type) {
            let glyphSize = CGSize(width: 72, height: 72)
            let origin = CGPoint(
                x: (size.width - glyphSize.width) / 2,
                y: (size.height - glyphSize.height) / 2
            )
            context.draw(glyphImage, in: CGRect(origin: origin, size: glyphSize))
        }

        guard let image = context.makeImage() else { return nil }
        return PlatformImageCodec.encodeJPEG(image, quality: 0.85)
    }

    /// 用 CoreText 渲染单个大写字母。
    ///
    /// 走 `CTFontCreateWithName` 而不是 NSFont / UIFont：
    /// 前者是 CoreText 的 C API，在 macOS 与 iOS 上都存在，且不需要引入 AppKit/UIKit。
    private func renderGlyph(for type: MaterialType) -> CGImage? {
        let letter = String(type.displayName.prefix(1)).uppercased()
        guard !letter.isEmpty else { return nil }

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 64, nil)
        let attributed = NSAttributedString(
            string: letter,
            attributes: [
                .init(kCTFontAttributeName as String): font,
                .init(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(bounds.width.rounded(.up)) + 4,
            height: Int(bounds.height.rounded(.up)) + 4,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.textPosition = CGPoint(x: 2 - bounds.origin.x, y: 2 - bounds.origin.y)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    /// 占位底色。用裸 RGB 而非 `Color`：SwiftUI 的 Color 属于 UI 表现层，
    /// 不该出现在产出缩略图字节的数据层里。
    private func placeholderColor(for type: MaterialType) -> CGColor {
        let rgb: (CGFloat, CGFloat, CGFloat) = {
            switch type {
            case .pdf: return (0.80, 0.22, 0.24)
            case .word: return (0.50, 0.30, 0.72)
            case .powerpoint: return (0.80, 0.30, 0.20)
            case .image: return (0.20, 0.45, 0.80)
            case .text: return (0.24, 0.58, 0.34)
            case .markdown: return (0.50, 0.30, 0.72)
            case .document: return (0.80, 0.52, 0.18)
            case .video: return (0.78, 0.32, 0.55)
            case .audio: return (0.16, 0.62, 0.66)
            case .other: return (0.45, 0.47, 0.50)
            }
        }()
        return CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }
}
