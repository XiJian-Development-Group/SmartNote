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
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptEnabled = true
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        
        if let htmlURL = Bundle.main.resourceURL?.appendingPathComponent("ciallo/index.html") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }
        
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
    }
}
