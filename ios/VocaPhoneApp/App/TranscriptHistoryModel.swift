import Foundation

/// Searching, filtering and grouping for the transcript library.
///
/// A list of ninety transcripts with no search is a list nobody opens twice.
/// Pure, so the grouping arithmetic — which is the part that goes wrong at
/// midnight and across time zones — can be tested without a store.
enum TranscriptHistoryModel {
    /// A day's worth of transcripts, under a heading a person recognises.
    struct Section: Equatable, Identifiable {
        let id: String
        let title: String
        let records: [SessionRecord]
    }

    struct Filter: Equatable {
        var query = ""
        /// `nil` means every route.
        var route: SessionProcessingLocation?
        /// `nil` means every style.
        var style: WritingStyle?

        var isActive: Bool { route != nil || style != nil || !query.isEmpty }
        var hasChips: Bool { route != nil || style != nil }
    }

    static func matches(_ record: SessionRecord, filter: Filter) -> Bool {
        if let route = filter.route, record.processingLocation != route { return false }
        if let style = filter.style, record.style != style.rawValue { return false }
        guard !filter.query.isEmpty else { return true }
        // Transcript text only. Searching the metadata as well would return
        // rows whose visible words do not contain the query, which reads as a
        // broken search.
        return (record.transcript ?? "").localizedCaseInsensitiveContains(filter.query)
    }

    static func filtered(_ records: [SessionRecord], filter: Filter) -> [SessionRecord] {
        records.filter { matches($0, filter: filter) }
    }

    /// Groups by day, newest first, with the two days people actually name.
    static func sections(
        _ records: [SessionRecord],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Section] {
        let sorted = records.sorted { $0.createdAt > $1.createdAt }
        var order: [Date] = []
        var grouped: [Date: [SessionRecord]] = [:]
        for record in sorted {
            let day = calendar.startOfDay(for: record.createdAt)
            if grouped[day] == nil { order.append(day) }
            grouped[day, default: []].append(record)
        }
        return order.map { day in
            Section(
                id: ISO8601DateFormatter().string(from: day),
                title: title(for: day, now: now, calendar: calendar),
                records: grouped[day] ?? []
            )
        }
    }

    static func title(for day: Date, now: Date, calendar: Calendar) -> String {
        // Measured against the supplied `now`, not the system clock:
        // `isDateInToday` would ignore the injected date and make midnight and
        // time-zone behaviour impossible to test.
        let today = calendar.startOfDay(for: now)
        if day == today { return "Today" }
        if day == calendar.date(byAdding: .day, value: -1, to: today) { return "Yesterday" }
        // Within the last week, the weekday alone is the most readable label.
        if let daysAgo = calendar.dateComponents([.day], from: day, to: now).day, daysAgo < 7 {
            return day.formatted(.dateTime.weekday(.wide))
        }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    /// Today's entries get a time; older ones already have a heading that says
    /// which day, so repeating the date in every row would be noise.
    static func timestamp(
        for record: SessionRecord,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if calendar.startOfDay(for: record.createdAt) == calendar.startOfDay(for: now) {
            return record.createdAt.formatted(date: .omitted, time: .shortened)
        }
        return record.createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    /// What the empty list should say, which depends on why it is empty.
    static func emptyMessage(for filter: Filter, hasAnyRecords: Bool) -> String {
        if !hasAnyRecords {
            return "Finish one dictation and it appears here, ready to copy or share."
        }
        if !filter.query.isEmpty {
            return "No transcript contains “\(filter.query)”."
        }
        return "No transcript matches the filters you have chosen."
    }
}
