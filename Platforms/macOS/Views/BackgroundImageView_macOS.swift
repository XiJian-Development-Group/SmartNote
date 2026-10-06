import SwiftUI
import AppKit

struct BackgroundImageView: View {
    @EnvironmentObject var appState: AppState_macOS

    var body: some View {
        let settings = appState.appSettings

        if settings.backgroundImageEnabled,
           let imageName = settings.effectiveBackgroundImageName {
            let imageURL = appState.storageService.getBackgroundImageURL(named: imageName)
            if let nsImage = NSImage(contentsOf: imageURL) {
                Image(nsImage: nsImage)
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