import SwiftUI
import AppKit

/// 菜单栏内的内容。设计为所有 P0 四个功能 + P1/P2 都完成后可继续扩展：
/// 当前阶段提供：主窗激活 / 快速新建 / 设置面板直达 / 开机自启状态。
///
/// SwiftUI 在 MenuBarExtra scene 里复用，所有数据来自 AppState 单例。
struct MenuBarContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var login = LaunchAtLoginService()
    @State private var quickNoteText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部状态
            headerSection
            Divider()

            // 快速记笔记
            quickNoteSection
            Divider()

            // 启动项
            loginSection
            Divider()

            // 操作
            actionsSection

            Divider()
            Button("退出智学笔记") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .frame(width: 280)
        .onAppear { login.refreshStatus() }
    }

    private var headerSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "book.fill")
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("智学笔记").font(.headline)
                Text("v\(appState.appSettings.schemaVersion) schema · 资料 \(appState.materials.count)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(8)
    }

    private var quickNoteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("快速记录").font(.caption).foregroundColor(.secondary)
            HStack {
                TextField("今天想记点什么…", text: $quickNoteText)
                    .textFieldStyle(.roundedBorder)
                Button("保存") {
                    if !quickNoteText.trimmingCharacters(in: .whitespaces).isEmpty {
                        appendQuickNote()
                    }
                }
                .disabled(quickNoteText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var loginSection: some View {
        Toggle(isOn: Binding(
            get: { login.enabledByUser },
            set: { newVal in
                login.setEnabled(newVal)
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("开机自启").font(.callout)
                Text(loginStatusText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .toggleStyle(.switch)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var loginStatusText: String {
        switch login.status {
        case .enabled: return "已注册到登录项"
        case .requiresApproval: return "需要去系统设置批准"
        case .notRegistered: return "未注册"
        case .notFound: return "系统未识别"
        @unknown default: return "未知状态"
        }
    }

    private var actionsSection: some View {
        VStack(spacing: 0) {
            Button {
                activateMainWindow(tab: 0)
            } label: {
                Label("资料库", systemImage: "folder.fill")
            }
            Button {
                activateMainWindow(tab: 10)
            } label: {
                Label("番茄钟", systemImage: "timer")
            }
            Button {
                activateMainWindow(tab: 20)
            } label: {
                Label("待办清单", systemImage: "checklist")
            }
            Button {
                activateMainWindow(tab: 22)
            } label: {
                Label("文件加密", systemImage: "lock.doc.fill")
            }
            Divider()
            Button {
                openSettings()
            } label: {
                Label("设置…", systemImage: "gear")
            }
        }
    }

    private func appendQuickNote() {
        // 落地到 study sessions 的"日记" / notes 形式：当前简化写到本地文本
        let notesDir = appState.storageService.appSupportURL.appendingPathComponent("QuickNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let url = notesDir.appendingPathComponent("\(day).md")
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
        let line = "## \(stamp)\n\n\(quickNoteText)\n\n"
        if FileManager.default.fileExists(atPath: url.path) {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                if let d = line.data(using: .utf8) { h.write(d) }
                try? h.close()
            }
        } else {
            try? line.data(using: .utf8)?.write(to: url, options: .atomic)
        }
        quickNoteText = ""
        NSApp.sendAction(#selector(NSPasteboard.general.clearContents), to: nil, from: nil)
    }

    private func activateMainWindow(tab: Int) {
        NSApp.activate(ignoringOtherApps: true)
        appState.selectedTab = tab
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
