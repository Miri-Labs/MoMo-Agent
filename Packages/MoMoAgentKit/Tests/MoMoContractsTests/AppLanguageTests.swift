import Foundation
import Testing
@testable import MoMoContracts

@Suite struct AppLanguageTests {
    @Test(arguments: [
        (["zh-CN"], AppLanguage.chinese), (["zh_Hant_TW"], .chinese),
        (["en-GB"], .english), (["ja_JP"], .japanese), (["ko-KR"], .korean),
        (["de-DE", "ja-JP", "en"], .japanese), (["fr-FR"], .english), ([], .english)
    ])
    func preferredSupportedLanguageWins(input: [String], expected: AppLanguage) {
        #expect(AppLanguage.resolve(input) == expected)
    }

    @Test(arguments: AppLanguage.allCases)
    func compiledResourcesContainPhoneWatchAndWidgetCopy(language: AppLanguage) throws {
        let path = try #require(AppLanguage.resourceBundle.path(forResource: language.rawValue, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let expected: [AppLanguage: [String]] = [
            .chinese: ["设置", "轻触以开始", "随身录音", "正在思考"],
            .english: ["Settings", "Tap to start", "Watch recording", "Thinking"],
            .japanese: ["設定", "タップして開始", "ウォッチで録音", "考え中"],
            .korean: ["설정", "탭하여 시작", "워치 녹음", "생각 중"]
        ]
        for (key, value) in zip(["设置", "轻触以开始", "随身录音", "正在思考"], try #require(expected[language])) {
            #expect(bundle.localizedString(forKey: key, value: nil, table: nil) == value)
        }
        let files = String(format: bundle.localizedString(forKey: "%@ 个文件", value: nil, table: nil), "3")
        #expect(files.contains("3"))
        #expect(!files.contains("%@"))
    }
}
