import SwiftUI
import WebKit

struct RelaxGameView: View {
    @State private var showAgreement = true
    @State private var isAgreed = false
    
    var body: some View {
        VStack(spacing: 0) {
            if showAgreement {
                agreementView
            } else if isAgreed {
                webViewContent
            }
        }
    }
    
    private var agreementView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            Text("使用提示")
                .font(.title)
                .fontWeight(.bold)
            
            Text("当前页面由 ciallo.cc 提供，如果您使用该功能，则智学笔记的开发者不对您的隐私安全提供保证。")
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Text("此外，感谢 ciallo.cc 的作者，如果您认为智学笔记开发者对您作品的使用属于侵权，请通过邮件联系我们：panmofan@icloud.com，我们会及时移除本功能。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Spacer()
            
            HStack(spacing: 20) {
                Button("取消") {
                    showAgreement = false
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                
                Button("确认") {
                    isAgreed = true
                    showAgreement = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            
            Spacer()
        }
        .padding()
    }
    
    private var webViewContent: some View {
        WebViewRepresentable()
    }
}

struct WebViewRepresentable: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.isInspectable = false

        // 只允许加载应用包内这一个入口文件；其余本地资源由 file read access 读取。
        if let htmlURL = Bundle.main.resourceURL?.appendingPathComponent("ciallo/index.html") {
            context.coordinator.allowedEntryURL = htmlURL
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var allowedEntryURL: URL?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // targetFrame == nil 表示 target=_blank/window.open；本功能永不创建新窗口。
            guard navigationAction.targetFrame != nil,
                  let url = navigationAction.request.url,
                  isAllowedEntryURL(url) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }

        private func isAllowedEntryURL(_ url: URL) -> Bool {
            guard url.isFileURL, let allowedEntryURL else { return false }
            let allowedPath = allowedEntryURL.standardizedFileURL.resolvingSymlinksInPath().path
            let requestedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
            return requestedPath == allowedPath
        }
    }
}
