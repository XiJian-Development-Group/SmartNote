import SwiftUI
import UIKit

/// iOS 版背景图视图。
///
/// **对应 macOS 的 `Platforms/macOS/Views/BackgroundImageView_macOS.swift`。**
///
/// 之前 iOS 完全没有这个视图：`ContentView_iOS` 只挂了 `ThemeBackdrop`，
/// 而它只画主题配色/渐变，**从不读取** `backgroundImageEnabled` /
/// `backgroundImageName`。结果是设置页里能选图、能删除、能随机切换，
/// `AppState_iOS` 也老老实实维护了 `backgroundImageActiveName`，
/// 但没有任何视图把它画出来 —— 表现为「背景图片不可用」。
///
/// 与 macOS 版的唯一差异：图片加载用 `UIImage(contentsOfFile:)` 而非
/// `NSImage(contentsOf:)`，其余判定逻辑与层级完全一致。
struct BackgroundImageView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS

    var body: some View {
        let settings = appState.appSettings

        if settings.backgroundImageEnabled,
           let imageName = settings.effectiveBackgroundImageName {
            let imageURL = appState.storageService.getBackgroundImageURL(named: imageName)
            if let uiImage = UIImage(contentsOfFile: imageURL.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(blurOverlay(settings: settings))
                    .opacity(settings.backgroundOpacity)
            }
        }
    }

    @ViewBuilder
    private func blurOverlay(settings: AppSettings) -> some View {
        if settings.backgroundBlurEnabled {
            Color.clear
                .background(.ultraThinMaterial)
                .blur(radius: settings.backgroundBlurRadius)
        }
    }
}
