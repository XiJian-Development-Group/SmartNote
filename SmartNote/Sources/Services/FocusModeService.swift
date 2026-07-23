import Foundation
import AppKit

class FocusModeService: ObservableObject {
    static let shared = FocusModeService()
    
    @Published var isActive = false
    @Published var isUnavailable = true
    
    private init() {}
    
    func enable() {
        isActive = true
    }
    
    func disable() {
        isActive = false
    }
}
