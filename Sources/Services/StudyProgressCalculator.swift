import Foundation

/// 목차의 장 하나에 대한 진도.
struct StudyChapterProgress: Equatable, Identifiable {
    let chapter: StudyOutlineChapter
    /// 이 장 범위 안에서 만든 카드·문제 수.
    let itemCount: Int
    /// 그중 "익힘"으로 볼 수 있는 수(§`StudyProgressCalculator.masteryIntervalDays`).
    let masteredCount: Int

    var id: Int { chapter.no }

    /// 이 장의 익힘도(0~1). 만든 항목이 없으면 0.
    var masteryRatio: Double {
        itemCount > 0 ? Double(masteredCount) / Double(itemCount) : 0
    }

    var hasItems: Bool { itemCount > 0 }
}

/// 교재 한 권의 진도 요약 — 화면이 그대로 그리면 되는 값들.
struct StudyProgressSummary: Equatable {
    let unit: StudyOutlineUnit
    /// 총 분량(쪽·줄·구간 수) = 세 비율의 공통 분모.
    let total: Int
    /// ①읽음 — 사용자가 읽었다고 체크한 장들의 분량 합.
    let readLength: Int
    /// ②만듦 — 카드·문제를 하나라도 만든 장들의 분량 합.
    let madeLength: Int
    /// ③익힘 — 장 분량 × 그 장 익힘도의 합(반올림 전 실수값).
    let masteredLength: Double
    let itemCount: Int
    let masteredItemCount: Int
    let chapters: [StudyChapterProgress]
    /// 위치를 알 수 없어(오피스 문서 등) 어느 장에도 못 붙인 항목 수 — 화면이 이유를 안내한다.
    let unplacedItemCount: Int

    var readRatio: Double { total > 0 ? Double(readLength) / Double(total) : 0 }
    var madeRatio: Double { total > 0 ? Double(madeLength) / Double(total) : 0 }
    var masteredRatio: Double { total > 0 ? masteredLength / Double(total) : 0 }
}

/// 목차 + 카드·문제(복습 상태 포함) → 진도 세 가지. 전부 순수 함수.
/// 설계 `2026-08-02-study-progress-design.md` §진도 3종 계산.
enum StudyProgressCalculator {

    /// "익힘"으로 보는 기준 — 다음 복습이 **3주 이상 뒤로 밀린** 항목.
    /// SM-2 계열에서 통상 쓰는 young/mature 경계값이고, 간격 상한 180일(§3.9)과도 맞는다.
    static let masteryIntervalDays = 21

    static func isMastered(_ state: StudyReviewState) -> Bool {
        state.interval >= masteryIntervalDays
    }

    static func summarize(outline: StudyOutline, items: [StudyIndexItem]) -> StudyProgressSummary {
        var itemsByChapter: [Int: [StudyIndexItem]] = [:]
        var unplaced = 0
        for item in items {
            if let no = chapterNumber(for: item.loc, unit: outline.unit, chapters: outline.chapters) {
                itemsByChapter[no, default: []].append(item)
            } else {
                unplaced += 1
            }
        }

        var chapters: [StudyChapterProgress] = []
        var readLength = 0
        var madeLength = 0
        var masteredLength = 0.0
        var masteredItems = 0

        for chapter in outline.chapters {
            let chapterItems = itemsByChapter[chapter.no] ?? []
            let mastered = chapterItems.filter { isMastered($0.state) }.count
            let progress = StudyChapterProgress(chapter: chapter, itemCount: chapterItems.count,
                                                masteredCount: mastered)
            chapters.append(progress)

            if chapter.read { readLength += chapter.length }
            if progress.hasItems { madeLength += chapter.length }
            masteredLength += Double(chapter.length) * progress.masteryRatio
            masteredItems += mastered
        }

        return StudyProgressSummary(
            unit: outline.unit, total: outline.total,
            readLength: readLength, madeLength: madeLength, masteredLength: masteredLength,
            itemCount: items.count, masteredItemCount: masteredItems,
            chapters: chapters, unplacedItemCount: unplaced)
    }

    /// 항목의 위치가 어느 장에 속하는지(장 번호). 위치를 알 수 없거나 어느 장에도 안 들면 nil.
    ///
    /// 오피스(한글·워드) 교재는 원본 위치를 알 방법이 없어 `loc`이 항상 `.unknown`이다(§5.2) —
    /// 그래서 오피스 교재는 지금 "읽음"만 잡히고 만듦·익힘은 0으로 나온다. 화면이 그 이유를
    /// 안내하고, 후속 조각에서 노트 frontmatter에 만든 범위를 남기는 방식으로 푼다.
    static func chapterNumber(for loc: StudyLocator, unit: StudyOutlineUnit,
                              chapters: [StudyOutlineChapter]) -> Int? {
        guard let position = position(of: loc, unit: unit) else { return nil }
        return chapters.first { position >= $0.start && position <= $0.end }?.no
    }

    /// 위치를 분량 단위의 숫자 하나로. 단위가 맞지 않으면 nil.
    static func position(of loc: StudyLocator, unit: StudyOutlineUnit) -> Int? {
        switch (loc, unit) {
        case (.page(let n), .page): return n
        case (.pageRange(let a, _), .page): return a
        case (.line(let n), .line): return n
        default: return nil
        }
    }
}
