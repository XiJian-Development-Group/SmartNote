import SwiftUI
import Combine

@MainActor
class AppState: ObservableObject {
    @Published var selectedTab: Int = 0
    @Published var showFileImporter: Bool = false
    @Published var isScanning: Bool = false
    @Published var isProcessingOCR: Bool = false
    @Published var isExtractingKeywords: Bool = false
    @Published var isAnalyzingWithAI: Bool = false
    @Published var materials: [StudyMaterial] = []
    @Published var selectedMaterial: StudyMaterial?
    @Published var extractedKeywords: [String] = []
    @Published var aiAnalysisResult: String = ""
    @Published var reviewPlans: [ReviewPlan] = []
    @Published var examCountdowns: [ExamCountdown] = []
    @Published var searchText: String = ""
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    
    let fileScanner = FileScannerService()
    let ocrService = OCRService()
    let keywordService = KeywordExtractionService()
    let calendarService = CalendarService()
    let storageService = StorageService()
    let speechService = SpeechService.shared
    let learningAnalysisService = LearningAnalysisService.shared
    let notificationService = NotificationService.shared
    let updateService: UpdateService
    var updateCheckCancellable: AnyCancellable? = nil
    var llmService: LLMService
    
    var llmConfiguration: LLMConfiguration {
        get { storageService.loadSettings().llmConfiguration }
        set {
            var settings = storageService.loadSettings()
            settings.llmConfiguration = newValue
            storageService.saveSettings(settings)
            llmService.updateConfiguration(newValue)
        }
    }
    
    init() {
        let settings = StorageService().loadSettings()
        let config = settings.llmConfiguration
        self.llmService = LLMService(configuration: config)
        // initialize update service with configured repo
        self.updateService = UpdateService(owner: settings.updateRepoOwner, repo: settings.updateRepoName)
        loadSavedData()

        // perform initial auto-check if enabled
        if settings.autoUpdateEnabled {
            Task {
                await performAutoCheckIfEnabled()
            }
        }

        // schedule automatic checks according to saved interval
        scheduleUpdateChecks(hoursInterval: settings.updateCheckIntervalHours)
    }

    func updateUpdateServiceRepositoryIfNeeded(owner: String, repo: String) {
        // update the service repository so manual checks use latest values
        updateService.updateRepository(owner: owner, repo: repo)
    }

    func scheduleUpdateChecks(hoursInterval: Int) {
        updateCheckCancellable?.cancel()
        let interval = max(1, hoursInterval)
        updateCheckCancellable = Timer.publish(every: TimeInterval(interval * 3600), on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task {
                    await self?.performAutoCheckIfEnabled()
                }
            }
    }

    func performAutoCheckIfEnabled() async {
        let settings = storageService.loadSettings()
        guard settings.autoUpdateEnabled else { return }
        let channel: UpdateService.Channel = (settings.updateChannel == .prerelease) ? .prerelease : .latest
        do {
            if let release = try await updateService.checkForUpdate(channel: channel) {
                var newSettings = settings
                newSettings.lastUpdateCheckDate = Date()
                newSettings.lastFoundReleaseName = release.name ?? release.tag_name
                storageService.saveSettings(newSettings)

                // auto download & install
                // notify user that update was found
                Task {
                    await updateService.notifyUserUpdateFound(release)
                }
                if newSettings.autoUpdateEnabled {
                    do {
                        _ = try await updateService.performDownloadAndInstall(release: release, autoInstall: true)
                    } catch {
                        // installation failed; leave downloaded files for manual install
                        print("Auto-install failed: \(error)")
                    }
                }
            } else {
                var newSettings = settings
                newSettings.lastUpdateCheckDate = Date()
                storageService.saveSettings(newSettings)
            }
        } catch {
            print("update check failed: \(error)")
        }
    }
    
    func loadSavedData() {
        materials = storageService.loadMaterials()
        reviewPlans = storageService.loadReviewPlans()
        examCountdowns = storageService.loadSettings().examCountdowns
    }
    
    func importFiles(_ urls: [URL], storageMode: MaterialStorageMode = .copy) {
        isScanning = true
        Task {
            let newMaterials = await fileScanner.scanFiles(urls: urls, storageMode: storageMode)
            await MainActor.run {
                materials.append(contentsOf: newMaterials)
                storageService.saveMaterials(materials)
                isScanning = false
            }
        }
    }
    
    func processOCR(for material: StudyMaterial) {
        guard let imageURL = material.localURL else { return }
        isProcessingOCR = true
        
        Task {
            let text = await ocrService.recognizeText(from: imageURL)
            await MainActor.run {
                if let index = materials.firstIndex(where: { $0.id == material.id }) {
                    materials[index].extractedText = text
                    storageService.saveMaterials(materials)
                }
                isProcessingOCR = false
            }
        }
    }
    
    func extractKeywords(for material: StudyMaterial) {
        let text = material.extractedText ?? material.content
        guard !text.isEmpty else { return }
        
        isExtractingKeywords = true
        Task {
            let keywords = keywordService.extractKeywords(from: text)
            await MainActor.run {
                if let index = materials.firstIndex(where: { $0.id == material.id }) {
                    materials[index].keywords = keywords
                    storageService.saveMaterials(materials)
                }
                extractedKeywords = keywords
                isExtractingKeywords = false
            }
        }
    }
    
    func analyzeWithAI(for material: StudyMaterial) {
        let text = material.extractedText ?? material.content
        guard !text.isEmpty else {
            errorMessage = "没有可分析的文本内容"
            showError = true
            return
        }
        
        guard llmConfiguration.enabled else {
            errorMessage = "请先在设置中启用 AI 分析功能"
            showError = true
            return
        }
        
        isAnalyzingWithAI = true
        aiAnalysisResult = ""
        
        Task {
            do {
                let result = try await llmService.analyzeText(text)
                await MainActor.run {
                    aiAnalysisResult = result
                    isAnalyzingWithAI = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                    isAnalyzingWithAI = false
                }
            }
        }
    }
    
    func generateSummaryWithAI(for material: StudyMaterial) {
        let text = material.extractedText ?? material.content
        guard !text.isEmpty else { return }
        guard llmConfiguration.enabled else { return }
        
        isAnalyzingWithAI = true
        aiAnalysisResult = ""
        
        Task {
            do {
                let result = try await llmService.generateSummary(text)
                await MainActor.run {
                    aiAnalysisResult = result
                    isAnalyzingWithAI = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                    isAnalyzingWithAI = false
                }
            }
        }
    }
    
    func createReviewPlan(examDate: Date, subject: String, topics: [String]) {
        let plan = calendarService.generateReviewPlan(
            examDate: examDate,
            subject: subject,
            topics: topics
        )
        reviewPlans.append(plan)
        storageService.saveReviewPlans(reviewPlans)
        
        Task {
            await calendarService.createCalendarEvents(for: plan)
        }
    }
    
    func deleteMaterial(_ material: StudyMaterial) {
        materials.removeAll { $0.id == material.id }
        storageService.saveMaterials(materials)
    }

    // 删除多个资料（批量操作）
    func deleteMaterials(withIDs ids: [UUID]) {
        materials.removeAll { ids.contains($0.id) }
        storageService.saveMaterials(materials)
    }
    
    var filteredMaterials: [StudyMaterial] {
        if searchText.isEmpty {
            return materials
        }
        return materials.filter { material in
            material.name.localizedCaseInsensitiveContains(searchText) ||
            (material.keywords?.contains { $0.localizedCaseInsensitiveContains(searchText) } ?? false) ||
            (material.content.localizedCaseInsensitiveContains(searchText))
        }
    }
}
