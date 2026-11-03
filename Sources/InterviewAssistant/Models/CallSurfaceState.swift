import Foundation
import Combine

@MainActor final class CallSurfaceState: ObservableObject {
    @Published private(set) var expanded = false
    @Published private(set) var hidden = false
    private var shownAnswerForQuestion = false
    func toggleExpanded() { expanded.toggle(); shownAnswerForQuestion = true }
    func collapse() { expanded = false; shownAnswerForQuestion = true }
    func hide() { hidden = true }
    func restore() { hidden = false }
    func beginQuestion() { shownAnswerForQuestion = false }
    func receiveAnswer(hasText: Bool) {
        guard hasText, !hidden, !shownAnswerForQuestion else { return }
        shownAnswerForQuestion = true; expanded = true
    }
}
