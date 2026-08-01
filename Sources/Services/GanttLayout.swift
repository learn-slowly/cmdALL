import Foundation

/// 할일 목록 "간트차트" 막대 위치 계산 — 전부 순수 함수(디스크·시간 흐름 관찰 없음, 호출부가
/// `today`를 넘긴다). 레고 결정: 모든 막대는 "오늘"에서 시작해 "마감일"까지 이어지고, 가로
/// 범위는 마감일 있는 할일 중 가장 늦은 날짜까지 자동으로 잡되 **오늘부터 6개월까지만**
/// 잡는다(레고 결정 2026-08-01). 6개월을 넘는 마감일은 막대 없이 날짜만, 마감일 없는 할일은
/// 제목만 목록으로 따로 보여준다.
enum GanttLayout {
    /// 간트차트가 그리는 최대 기간(개월).
    static let horizonMonths = 6

    /// 오늘부터 `months`개월 뒤 — 간트차트 가로축이 넘어갈 수 없는 상한.
    static func horizonEnd(today: Date, months: Int = horizonMonths, calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: today)
        return calendar.date(byAdding: .month, value: months, to: startOfToday) ?? startOfToday
    }

    /// 상한을 넘는 먼 미래 마감일인가 — 참이면 간트차트에서 빼고 날짜만 목록으로 보여준다.
    static func isBeyondHorizon(due: Date, today: Date, months: Int = horizonMonths, calendar: Calendar = .current) -> Bool {
        let limit = horizonEnd(today: today, months: months, calendar: calendar)
        return calendar.startOfDay(for: due) > calendar.startOfDay(for: limit)
    }

    /// 전체 가로축의 끝 — 마감일 있는 할일 중 가장 늦은(미래) 날짜. 단 상한(6개월)을 넘는
    /// 날짜는 무시한다. 전부 지났거나 목록이 비었으면 오늘(막대가 전부 지난 상태로만 보이게).
    static func rangeEnd(dueDates: [Date], today: Date, months: Int = horizonMonths, calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: today)
        let future = dueDates.filter {
            calendar.startOfDay(for: $0) >= startOfToday
                && !isBeyondHorizon(due: $0, today: today, months: months, calendar: calendar)
        }
        return future.max() ?? startOfToday
    }

    /// 막대 끝 위치를 0.0(오늘)~1.0(rangeEnd) 비율로 돌려준다. 이미 지난 마감일은 0.0(막대가
    /// 거의 안 보이는 상태로 그려 "지났다"를 표시 — 실제 마이너스 길이는 없다).
    static func barFraction(today: Date, due: Date, rangeEnd: Date, calendar: Calendar = .current) -> Double {
        let startOfToday = calendar.startOfDay(for: today)
        let endOfRange = calendar.startOfDay(for: rangeEnd)
        let dueDay = calendar.startOfDay(for: due)
        guard dueDay >= startOfToday else { return 0.0 }

        let totalDays = calendar.dateComponents([.day], from: startOfToday, to: endOfRange).day ?? 0
        guard totalDays > 0 else { return 1.0 }   // 범위가 하루뿐이면(오늘이 마감) 꽉 채운다.

        let dueDays = calendar.dateComponents([.day], from: startOfToday, to: dueDay).day ?? 0
        return min(max(Double(dueDays) / Double(totalDays), 0.0), 1.0)
    }

    static func isOverdue(due: Date, today: Date, calendar: Calendar = .current) -> Bool {
        calendar.startOfDay(for: due) < calendar.startOfDay(for: today)
    }

    // MARK: - 가로축 눈금(레고 요청 2026-08-01 — "1개월 단위라도 선을, 1주 단위면 더 좋고")

    /// 주 단위 눈금을 쓰는 최대 기간(일). 이보다 길면 선이 너무 촘촘해져 월 단위로 바꾼다.
    static let weeklyTickMaxDays = 84

    /// 눈금 하나 — 날짜와 가로 위치(0.0=오늘, 1.0=차트 끝).
    struct Tick: Equatable, Identifiable {
        let date: Date
        let fraction: Double
        var id: Date { date }
    }

    /// 눈금 간격 — 주 단위(달력의 주 시작 요일)냐 월 단위(매달 1일)냐.
    enum TickUnit: Equatable {
        case week
        case month
    }

    struct Axis: Equatable {
        let unit: TickUnit
        let ticks: [Tick]
    }

    /// 오늘~차트 끝 사이의 눈금 목록. 12주 이내면 주 단위, 그보다 길면 월 단위. 오늘 당일(끝==오늘)이면
    /// 그릴 눈금이 없다(빈 배열).
    static func axis(today: Date, rangeEnd: Date, calendar: Calendar = .current) -> Axis {
        let start = calendar.startOfDay(for: today)
        let end = calendar.startOfDay(for: rangeEnd)
        let totalDays = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        guard totalDays > 0 else { return Axis(unit: .week, ticks: []) }

        let unit: TickUnit = totalDays <= weeklyTickMaxDays ? .week : .month
        let matching = unit == .week
            ? DateComponents(hour: 0, minute: 0, second: 0, weekday: calendar.firstWeekday)
            : DateComponents(day: 1, hour: 0, minute: 0, second: 0)
        let dates = boundaries(after: start, until: end, matching: matching, calendar: calendar)
        let ticks = dates.map {
            Tick(date: $0, fraction: barFraction(today: start, due: $0, rangeEnd: end, calendar: calendar))
        }
        return Axis(unit: unit, ticks: ticks)
    }

    /// `start` 다음부터 `end`까지, 주어진 달력 조건(주 시작 요일 또는 매달 1일)에 맞는 날짜들.
    private static func boundaries(after start: Date, until end: Date, matching: DateComponents, calendar: Calendar) -> [Date] {
        var result: [Date] = []
        var cursor = start
        while result.count < 64 {
            guard let next = calendar.nextDate(after: cursor,
                                               matching: matching,
                                               matchingPolicy: .nextTime,
                                               direction: .forward) else { break }
            let day = calendar.startOfDay(for: next)
            guard day <= end else { break }
            guard day > cursor else { break }   // 전진하지 않으면 무한루프 방지.
            result.append(day)
            cursor = day
        }
        return result
    }
}
