import Foundation
import InterviewCore

enum AppAnswerProviders {
    static func makeDefault() -> AnswerProvider {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CluelessFastAnswer")
        return OpeningAndDetailProvider(opening: ProtectedFastAnswerProvider(helperURL: helper), detail: CodexAnswerProvider(model: "gpt-6-luna"))
    }
}
