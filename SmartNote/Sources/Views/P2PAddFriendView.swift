import SwiftUI

struct P2PAddFriendView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var p2pService = P2PService.shared

    @State private var ipv6Address = ""
    @State private var port = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("添加好友")
                    .font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("对方 IPv6 地址")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                TextField("例如: 2001:db8::1", text: $ipv6Address)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("端口")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                TextField("例如: 8080", text: $port)
                    .textFieldStyle(.roundedBorder)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Divider()

            VStack(spacing: 8) {
                Text("你的连接信息")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack {
                    Text("IPv6: \(p2pService.getIPv6Address())")
                        .font(.caption)
                        .textSelection(.enabled)

                    Spacer()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(p2pService.getIPv6Address()):\(p2pService.getPort())", forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .help("复制地址")
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                Text("将以上地址发给好友，等待对方连接")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: connectToFriend) {
                HStack {
                    if isConnecting {
                        ProgressView().controlSize(.small)
                    }
                    Text(isConnecting ? "连接中..." : "连接")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(ipv6Address.isEmpty || port.isEmpty || isConnecting)
        }
        .padding()
        .frame(width: 400, height: 450)
    }

    private func connectToFriend() {
        guard let portInt = Int(port), portInt > 0, portInt <= 65535 else {
            errorMessage = "端口必须是 1-65535 之间的数字"
            return
        }
        isConnecting = true
        errorMessage = nil

        let result = p2pService.connectToFriend(ipv6Address: ipv6Address, port: portInt)

        if result == nil {
            errorMessage = "对方已在黑名单中，或连接失败"
            isConnecting = false
        } else {
            errorMessage = "连接已建立，等待对方确认..."
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                isConnecting = false
                dismiss()
            }
        }
    }
}
