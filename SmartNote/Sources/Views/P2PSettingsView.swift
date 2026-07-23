import SwiftUI

struct P2PSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var p2pService = P2PService.shared
    @State private var showResetConfirmation = false
    @State private var showBlackListEditor = false
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("社交设置")
                    .font(.headline)
                Spacer()
                Button("关闭") {
                    dismiss()
                }
            }
            .padding()
            
            Divider()
            
            List {
                Section("连接信息") {
                    if let identity = p2pService.currentIdentity {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("IPv6 地址")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            Text(identity.ipv6Address)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            
                            Text("端口: \(identity.port)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("密钥指纹")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            Text(identity.keyFingerprint)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                Section("后台设置") {
                    Toggle("允许后台常驻接收消息", isOn: Binding(
                        get: { p2pService.isBackgroundEnabled },
                        set: { p2pService.setBackgroundEnabled($0) }
                    ))
                    
                    Text("开启后台常驻会占用少量系统资源用于维持P2P直连消息接收")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section("黑名单管理") {
                    Button {
                        showBlackListEditor = true
                    } label: {
                        HStack {
                            Image(systemName: "person.crop.circle.badge.xmark")
                            Text("管理黑名单 (\(p2pService.blackList.count))")
                        }
                    }
                }
                
                Section("身份管理") {
                    Button {
                        showResetConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: "arrow.counterclockwise")
                            Text("重置身份")
                        }
                        .foregroundColor(.red)
                    }
                }
                
                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                        Text(version)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("加密方式")
                        Spacer()
                        Text("RSA-2048 + AES-256")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .alert("确认重置", isPresented: $showResetConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确认重置", role: .destructive) {
                p2pService.resetIdentity()
                dismiss()
            }
        } message: {
            Text("重置将删除所有好友、聊天记录和密钥对，此操作不可恢复")
        }
        .sheet(isPresented: $showBlackListEditor) {
            P2PBlackListView()
        }
    }
}

struct P2PBlackListView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var p2pService = P2PService.shared
    @State private var newIP = ""
    @State private var newReason = ""
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("黑名单管理")
                    .font(.headline)
                Spacer()
                Button("关闭") {
                    dismiss()
                }
            }
            .padding()
            
            Divider()
            
            List {
                if p2pService.blackList.isEmpty {
                    VStack {
                        Image(systemName: "checkmark.shield")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("黑名单为空")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                } else {
                    ForEach(p2pService.blackList) { ip in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(ip.ipv6Address)
                                    .font(.system(.body, design: .monospaced))
                                if !ip.reason.isEmpty {
                                    Text(ip.reason)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Spacer()
                            
                            Button {
                                p2pService.removeFromBlackList(ipv6Address: ip.ipv6Address)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            
            Divider()
            
            VStack(spacing: 12) {
                TextField("IPv6 地址", text: $newIP)
                    .textFieldStyle(.roundedBorder)
                
                TextField("原因（可选）", text: $newReason)
                    .textFieldStyle(.roundedBorder)
                
                Button {
                    addToBlackList()
                } label: {
                    Text("添加到黑名单")
                }
                .buttonStyle(.borderedProminent)
                .disabled(newIP.isEmpty)
            }
            .padding()
        }
    }
    
    private func addToBlackList() {
        p2pService.addToBlackList(ipv6Address: newIP, reason: newReason)
        newIP = ""
        newReason = ""
    }
}
