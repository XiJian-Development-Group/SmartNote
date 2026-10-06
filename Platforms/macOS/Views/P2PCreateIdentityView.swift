import SwiftUI

struct P2PCreateIdentityView: View {
    @StateObject private var p2pService = P2PService.shared
    @State private var nickname = ""
    @State private var signature = ""
    @State private var avatarImage: NSImage?
    @State private var isCreating = false
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(spacing: 16) {
            Button {
                selectAvatar()
            } label: {
                if let image = avatarImage {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: 80, height: 80)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            
            Text("点击选择头像")
                .font(.caption)
                .foregroundColor(.secondary)
            
            TextField("昵称", text: $nickname)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            
            TextField("个性签名（可选）", text: $signature)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            
            Button {
                createIdentity()
            } label: {
                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("创建身份")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(nickname.isEmpty || isCreating)
        }
    }
    
    private func selectAvatar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let url = panel.url {
            avatarImage = NSImage(contentsOf: url)
        }
    }
    
    private func createIdentity() {
        isCreating = true
        errorMessage = nil
        
        let avatarData = avatarImage?.tiffRepresentation
        
        DispatchQueue.global().async {
            let success = p2pService.createIdentity(
                nickname: nickname,
                signature: signature,
                avatarData: avatarData
            )
            
            DispatchQueue.main.async {
                isCreating = false
                if !success {
                    errorMessage = "创建身份失败，请重试"
                }
            }
        }
    }
}
