import Foundation

/// 할일 목록 "간트차트" 막대 위치 계산 — 전부 순수 함수(디스크·시간 흐름 관찰 없음, 호출부가
/// `today`를 넘긴다). 레고 결정: 모든 막대는 "오늘"에서 시작해 "마감일"까지 이어지고, 가로
/// 범위는 마감일 있는 할일 중 가장 늦은 날짜까지 자동으로 잡는다.
enum GanttLayout {
    /// 전체 가로축의 끝 — 마감일 있는 할일 중 가장 늦은(미래) 날짜. 전부 지났거나 목록이
    /// 비었으면 오늘(막대가 전부 지난 상태로만 보이게).
    static func rangeEnd(dueDates: [Date], today: Date, calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: today)
        let future = dueDates.filter { calendar.startOfDay(for: $0) >= startOfToday }
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
}
