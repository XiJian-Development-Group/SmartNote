import SwiftUI

/// 设置页「日记加密」区块。
///
/// 密码、密保问题与答案只写入钥匙串（见 `DiaryEncryptionService`），UI 不持久化任何明文；
/// 加密开关本身只是一个非敏感布尔值。加密失败时直接把原因展示给用户，不静默降级。
struct DiaryEncryptionSettingsSection: View {
    @State private var isEnabled: Bool = false
    @State private var hasSecurityAnswer: Bool = false

    @State private var password: String = ""
    @State private var confirmation: String = ""
    @State private var securityQuestion: String = ""
    @State private var securityAnswer: String = ""

    @State private var errorMessage: String?
    @State private var showDisableConfirmation: Bool = false

    private let service = DiaryEncryptionService.shared

    var body: some View {
        Section {
            HStack {
                Image(systemName: isEnabled ? "lock.shield.fill" : "lock.open")
                    .foregroundColor(isEnabled ? .green : .secondary)
                Text(isEnabled ? "日记加密已启用" : "日记加密未启用")
                Spacer()
                Text(isEnabled ? "AES-GCM" : "明文")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if isEnabled {
                Label("密码保存在本机钥匙串，不会写入 settings.json。", systemImage: "key.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if hasSecurityAnswer {
                    Label("已设置密保问题", systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text("暂不支持修改密码：更换密码会导致已加密日记无法解密。需要更换时请先关闭加密。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("关闭日记加密") {
                    showDisableConfirmation = true
                }
                .foregroundColor(.red)
            } else {
                SecureField("密码（至少 \(DiaryEncryptionService.minimumPasswordLength) 位）", text: $password)
                SecureField("再次输入密码", text: $confirmation)

                TextField("密保问题（可选）", text: $securityQuestion)
                SecureField("密保答案（可选）", text: $securityAnswer)

                Text("启用后，新保存或修改的日记正文会加密（本地 AES-GCM + PBKDF2）。已有明文日记会在你下次编辑保存时转为加密；标题、分类、图片等元数据不加密。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("启用日记加密") {
                    enableEncryption()
                }
                .disabled(password.isEmpty)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        } header: {
            Text("日记加密")
        } footer: {
            Text("若本机钥匙串被清空，已加密的日记将无法恢复。")
        }
        .onAppear(perform: refreshStatus)
        .alert("关闭日记加密？", isPresented: $showDisableConfirmation) {
            Button("取消", role: .cancel) {}
            Button("关闭加密", role: .destructive) {
                disableEncryption()
            }
        } message: {
            Text("关闭后，日记正文将恢复为明文存储，任何能读取本机文件的人都可以直接查看。")
        }
    }

    private func refreshStatus() {
        isEnabled = service.isEncryptionEnabled()
        hasSecurityAnswer = service.hasSecurityAnswer()
    }

    private func enableEncryption() {
        errorMessage = nil
        do {
            try service.enableEncryption(
                password: password,
                confirmation: confirmation,
                securityQuestion: securityQuestion,
                securityAnswer: securityAnswer
            )
            // 密码只留在钥匙串：立刻清空输入框，避免明文长时间停留在内存/剪贴板历史。
            password = ""
            confirmation = ""
            securityQuestion = ""
            securityAnswer = ""
            refreshStatus()
        } catch {
            errorMessage = describe(error)
        }
    }

    private func disableEncryption() {
        errorMessage = nil
        do {
            try service.disableEncryption(confirmed: true)
            refreshStatus()
        } catch {
            errorMessage = describe(error)
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
