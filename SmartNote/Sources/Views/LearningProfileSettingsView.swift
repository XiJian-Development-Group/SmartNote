import SwiftUI

struct LearningProfileSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var profile: UserLearningProfile
    @State private var isRefreshing = false
    @State private var lastAutoTuneSummary: String = ""

    init() {
        _profile = State(initialValue: LearningAnalysisService.shared.currentProfile)
    }
    
    var body: some View {
        Form {
            Section("智能学习分析") {
                Toggle("启用学习偏好分析", isOn: Binding(
                    get: { profile.isEnabled },
                    set: { newValue in
                        profile.isEnabled = newValue
                        appState.learningAnalysisService.setEnabled(newValue)
                    }
                ))
                
                if profile.isEnabled {
                    Picker("自动分析频率", selection: Binding(
                        get: { profile.analysisFrequency },
                        set: { newValue in
                            profile.analysisFrequency = newValue
                            appState.learningAnalysisService.setAnalysisFrequency(newValue)
                        }
                    )) {
                        ForEach(AnalysisFrequency.allCases, id: \.self) { frequency in
                            Text(frequency.description).tag(frequency)
                        }
                    }

                    HStack {
                        Button {
                            refreshNow()
                        } label: {
                            HStack {
                                if isRefreshing {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                }
                                Text("立即刷新")
                            }
                        }
                        .disabled(isRefreshing || !appState.llmConfiguration.enabled)

                        Button {
                            runLocalAutoTune()
                        } label: {
                            Label("本地启发式调优", systemImage: "wand.and.stars")
                        }
                        .help("不调 LLM，本地从资料 / 错题 / 复习计划中提取薄弱科目与近期话题。")
                        .disabled(appState.materials.isEmpty)

                        Spacer()

                        if let lastDate = profile.lastAnalysisDate {
                            Text("上次: \(lastDate, formatter: dateFormatter)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if !lastAutoTuneSummary.isEmpty {
                        Text(lastAutoTuneSummary)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    }
                }
            }
            
            Section("学习偏好") {
                Picker("讲解风格", selection: $profile.preferences.preferredExplanationStyle) {
                    ForEach(ExplanationStyle.allCases, id: \.self) { style in
                        Text(style.description).tag(style)
                    }
                }
                
                Picker("难度", selection: $profile.preferences.preferredDifficulty) {
                    ForEach(DifficultyLevel.allCases, id: \.self) { level in
                        Text(level.description).tag(level)
                    }
                }
                
                Picker("语言风格", selection: $profile.preferences.preferredLanguageTone) {
                    ForEach(LanguageTone.allCases, id: \.self) { tone in
                        Text(tone.description).tag(tone)
                    }
                }
                
                Picker("复习方式", selection: $profile.preferences.preferredReviewMethod) {
                    ForEach(ReviewMethod.allCases, id: \.self) { method in
                        Text(method.description).tag(method)
                    }
                }
                
                Section("薄弱科目") {
                    EditableTextList(
                        items: $profile.preferences.weakSubjects,
                        placeholder: "添加薄弱科目"
                    )
                }
                
                Section("擅长科目") {
                    EditableTextList(
                        items: $profile.preferences.strongSubjects,
                        placeholder: "添加擅长科目"
                    )
                }
                
                Section("需要注意的知识点") {
                    EditableTextList(
                        items: $profile.preferences.attentionPoints,
                        placeholder: "添加需要注意的知识点"
                    )
                }
                
                Button("保存偏好设置") {
                    appState.learningAnalysisService.updatePreferences(profile.preferences)
                }
                .buttonStyle(.borderedProminent)
            }
            
            Section("学习特征") {
                Picker("偏好学习时间", selection: $profile.characteristics.preferredStudyTime) {
                    ForEach(StudyTime.allCases, id: \.self) { time in
                        Text(time.description).tag(time)
                    }
                }
                
                Picker("学习节奏", selection: $profile.characteristics.learningPace) {
                    ForEach(LearningPace.allCases, id: \.self) { pace in
                        Text(pace.description).tag(pace)
                    }
                }
                
                Picker("记忆类型", selection: $profile.characteristics.memoryType) {
                    ForEach(MemoryType.allCases, id: \.self) { type in
                        Text(type.description).tag(type)
                    }
                }
                
                Picker("笔记风格", selection: $profile.characteristics.noteTakingStyle) {
                    ForEach(NoteTakingStyle.allCases, id: \.self) { style in
                        Text(style.description).tag(style)
                    }
                }
                
                Picker("提问频率", selection: $profile.characteristics.questionFrequency) {
                    ForEach(QuestionFrequency.allCases, id: \.self) { freq in
                        Text(freq.description).tag(freq)
                    }
                }
                
                Button("保存特征设置") {
                    appState.learningAnalysisService.updateCharacteristics(profile.characteristics)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            profile = appState.learningAnalysisService.currentProfile
        }
    }
    
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }
    
    private func refreshNow() {
        isRefreshing = true
        Task {
            await appState.learningAnalysisService.refreshNow()
            await MainActor.run {
                isRefreshing = false
                profile = appState.learningAnalysisService.currentProfile
            }
        }
    }

    private func runLocalAutoTune() {
        let suggestion = appState.learningAnalysisService.autoTuneLocally()
        profile = appState.learningAnalysisService.currentProfile
        var parts: [String] = []
        if !suggestion.weakSubjects.isEmpty { parts.append("薄弱：\(suggestion.weakSubjects.joined(separator: "、"))") }
        if !suggestion.strongSubjects.isEmpty { parts.append("擅长：\(suggestion.strongSubjects.joined(separator: "、"))") }
        if !suggestion.recentTopics.isEmpty { parts.append("近期：\(suggestion.recentTopics.prefix(3).joined(separator: "、"))") }
        parts.append("推荐记忆类型：\(suggestion.suggestedMemoryType.description)")
        lastAutoTuneSummary = parts.joined(separator: "  ")
    }
}

struct EditableTextList: View {
    @Binding var items: [String]
    let placeholder: String
    
    @State private var newItem = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items.indices, id: \.self) { index in
                HStack {
                    Text(items[index])
                    Spacer()
                    Button {
                        items.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            HStack {
                TextField(placeholder, text: $newItem)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if !newItem.isEmpty {
                            items.append(newItem)
                            newItem = ""
                        }
                    }
                
                Button {
                    if !newItem.isEmpty {
                        items.append(newItem)
                        newItem = ""
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
                .disabled(newItem.isEmpty)
            }
        }
    }
}
