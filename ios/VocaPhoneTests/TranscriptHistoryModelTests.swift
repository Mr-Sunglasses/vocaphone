import Foundation
import Testing

struct TranscriptHistoryModelTests {
    private static let calendar = Calendar(identifier: .gregorian)
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static func record(
        daysAgo: Double = 0,
        transcript: String = "hello",
        style: WritingStyle = .casual,
        location: SessionProcessingLocation? = nil
    ) -> SessionRecord {
        var record = SessionRecord(
            style: style.rawValue,
            now: now.addingTimeInterval(-daysAgo * 24 * 60 * 60)
        )
        record.transcript = transcript
        record.processingLocation = location
        return record
    }

    // MARK: - Search

    /// Transcript text only. Matching the metadata as well would return rows
    /// whose visible words do not contain the query, which reads as broken.
    @Test func searchMatchesTranscriptTextAndNothingElse() {
        let record = Self.record(transcript: "Ship the beta on Friday", style: .formal)
        var filter = TranscriptHistoryModel.Filter(query: "beta")
        #expect(TranscriptHistoryModel.matches(record, filter: filter))

        filter.query = "BETA"
        #expect(TranscriptHistoryModel.matches(record, filter: filter))

        filter.query = "formal"
        #expect(!TranscriptHistoryModel.matches(record, filter: filter))
    }

    @Test func anEmptyQueryMatchesEverything() {
        #expect(
            TranscriptHistoryModel.matches(
                Self.record(),
                filter: TranscriptHistoryModel.Filter()
            )
        )
    }

    // MARK: - Filters

    @Test func filtersNarrowByRouteAndStyle() {
        let onDevice = Self.record(transcript: "one", style: .formal, location: .onDevice)
        let gateway = Self.record(transcript: "two", style: .casual, location: .gateway)
        let records = [onDevice, gateway]

        var filter = TranscriptHistoryModel.Filter()
        filter.route = .onDevice
        #expect(TranscriptHistoryModel.filtered(records, filter: filter).count == 1)

        filter.route = nil
        filter.style = .casual
        #expect(
            TranscriptHistoryModel.filtered(records, filter: filter).first?.transcript == "two"
        )

        // Both at once, and they intersect rather than accumulate.
        filter.route = .onDevice
        #expect(TranscriptHistoryModel.filtered(records, filter: filter).isEmpty)
    }

    /// A record from before the route was written down matches "any source" but
    /// not a specific one — claiming it ran on the gateway would be a guess.
    @Test func aRecordWithNoRouteIsNotClaimedByEitherFilter() {
        let legacy = Self.record(location: nil)
        var filter = TranscriptHistoryModel.Filter()
        #expect(TranscriptHistoryModel.matches(legacy, filter: filter))
        filter.route = .gateway
        #expect(!TranscriptHistoryModel.matches(legacy, filter: filter))
        filter.route = .onDevice
        #expect(!TranscriptHistoryModel.matches(legacy, filter: filter))
    }

    // MARK: - Grouping

    @Test func sectionsGroupByDayNewestFirst() {
        let records = [
            Self.record(daysAgo: 0, transcript: "today one"),
            Self.record(daysAgo: 0, transcript: "today two"),
            Self.record(daysAgo: 1, transcript: "yesterday"),
            Self.record(daysAgo: 9, transcript: "old"),
        ]
        let sections = TranscriptHistoryModel.sections(
            records,
            now: Self.now,
            calendar: Self.calendar
        )
        #expect(sections.count == 3)
        #expect(sections[0].records.count == 2)
        #expect(sections[0].title == "Today")
        #expect(sections[1].title == "Yesterday")
        // Older than a week gets a date rather than a weekday nobody can place.
        #expect(sections[2].title != "Today" && sections[2].title != "Yesterday")
    }

    @Test func withinTheLastWeekTheWeekdayIsEnough() {
        let title = TranscriptHistoryModel.title(
            for: Self.calendar.startOfDay(for: Self.now.addingTimeInterval(-3 * 86_400)),
            now: Self.now,
            calendar: Self.calendar
        )
        #expect(!title.isEmpty)
        #expect(title != "Today")
        #expect(title != "Yesterday")
    }

    /// Today's rows already sit under a heading that says "Today", so repeating
    /// the date in every one of them would be noise.
    @Test func todaysRowsShowATimeAndOlderOnesADate() {
        let today = TranscriptHistoryModel.timestamp(
            for: Self.record(daysAgo: 0),
            now: Self.now,
            calendar: Self.calendar
        )
        let older = TranscriptHistoryModel.timestamp(
            for: Self.record(daysAgo: 5),
            now: Self.now,
            calendar: Self.calendar
        )
        #expect(today.count < older.count)
    }

    @Test func noRecordsMeansNoSections() {
        #expect(TranscriptHistoryModel.sections([], now: Self.now).isEmpty)
    }

    // MARK: - Empty states

    /// Three different reasons for an empty list, and three different things
    /// worth saying about it.
    @Test func theEmptyMessageExplainsWhichEmptyThisIs() {
        let none = TranscriptHistoryModel.emptyMessage(
            for: TranscriptHistoryModel.Filter(),
            hasAnyRecords: false
        )
        #expect(none.contains("Finish one dictation"))

        let searched = TranscriptHistoryModel.emptyMessage(
            for: TranscriptHistoryModel.Filter(query: "zebra"),
            hasAnyRecords: true
        )
        #expect(searched.contains("zebra"))

        var filtered = TranscriptHistoryModel.Filter()
        filtered.route = .onDevice
        #expect(
            TranscriptHistoryModel.emptyMessage(for: filtered, hasAnyRecords: true)
                .contains("filters")
        )
    }
}

struct TranscriptRetentionTests {
    @Test func everyOptionSaysWhatItDoes() {
        for option in TranscriptRetention.allCases {
            #expect(!option.displayName.isEmpty)
            #expect(!option.detail.isEmpty)
        }
    }

    /// The default keeps everything: deleting someone's words because a setting
    /// defaulted to a duration they never chose would be the wrong surprise.
    @Test func theDefaultKeepsEverything() {
        #expect(TranscriptRetention.default == .forever)
        #expect(TranscriptRetention.forever.maximumAge == nil)
        #expect(TranscriptRetention.fromStored(nil) == .forever)
        #expect(TranscriptRetention.fromStored("nonsense") == .forever)
        #expect(TranscriptRetention.fromStored("7d") == .sevenDays)
    }

    @Test func theWindowsAreOrdered() {
        #expect(TranscriptRetention.sevenDays.maximumAge! < TranscriptRetention.thirtyDays.maximumAge!)
    }
}
