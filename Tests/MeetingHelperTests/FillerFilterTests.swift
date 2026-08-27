import XCTest
@testable import MeetingHelper

/// The filter matches verbatim model output, so the phrases below are data rather than interface
/// text and stay in the languages Whisper produces them in.
final class FillerFilterTests: XCTestCase {
    func testDropsBackchannelsInTheirManySpellings() {
        XCTAssertTrue(FillerFilter.isFiller("Mm-hmm."))
        XCTAssertTrue(FillerFilter.isFiller("Mm."))
        XCTAssertTrue(FillerFilter.isFiller("Mm-mm-mm."))
        XCTAssertTrue(FillerFilter.isFiller("Hmm."))
        XCTAssertTrue(FillerFilter.isFiller("Um..."))
        XCTAssertTrue(FillerFilter.isFiller("Ummm,"))
        XCTAssertTrue(FillerFilter.isFiller("um"))
        XCTAssertTrue(FillerFilter.isFiller("Uh,"))
        XCTAssertTrue(FillerFilter.isFiller("Uh-huh."))
        XCTAssertTrue(FillerFilter.isFiller("Ooh."))
        XCTAssertTrue(FillerFilter.isFiller("Ugh."))
        XCTAssertTrue(FillerFilter.isFiller("Aww."))
        XCTAssertTrue(FillerFilter.isFiller("Э-э..."))
        XCTAssertTrue(FillerFilter.isFiller("Эм."))
        XCTAssertTrue(FillerFilter.isFiller("Угу."))
    }

    func testDropsPhrasesWithNoLettersAtAll() {
        XCTAssertTrue(FillerFilter.isFiller("-"))
        XCTAssertTrue(FillerFilter.isFiller("..."))
    }

    func testKeepsSpokenNumbers() {
        XCTAssertFalse(FillerFilter.isFiller("3-5%, 2%."))
        XCTAssertFalse(FillerFilter.isFiller("11"))
    }

    func testKeepsShortRealAnswers() {
        XCTAssertFalse(FillerFilter.isFiller("Да."))
        XCTAssertFalse(FillerFilter.isFiller("Нет."))
        XCTAssertFalse(FillerFilter.isFiller("Окей."))
        XCTAssertFalse(FillerFilter.isFiller("Понял."))
        XCTAssertFalse(FillerFilter.isFiller("Okay."))
        XCTAssertFalse(FillerFilter.isFiller("Yeah."))
        XCTAssertFalse(FillerFilter.isFiller("No."))
        XCTAssertFalse(FillerFilter.isFiller("What?"))
        // Confusion asks for a repeat, which is an utterance with a job.
        XCTAssertFalse(FillerFilter.isFiller("Huh?"))
    }

    func testKeepsSentencesThatStartWithAFiller() {
        XCTAssertFalse(FillerFilter.isFiller("Um, I think we should ship it."))
        XCTAssertFalse(FillerFilter.isFiller("Эм, давай посмотрим цифры."))
    }
}
