import SwiftUI

struct WhiteBoardView: View {
    @State private var showComingSoon = true
    
    var body: some View {
        VStack {
            if showComingSoon {
                VStack(spacing: 24) {
                    Spacer()
                    
                    Image(systemName: "hammer")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    
                    Text("该功能正在开发中")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("暂时不开放使用")
                        .font(.body)
                        .foregroundColor(.secondary)
                    
                    Button("确定") {
                        showComingSoon = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
