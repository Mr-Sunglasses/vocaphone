import Foundation
import Testing

struct DownloadReadinessTests {
    private let large: Int64 = 670_000_000
    private let small: Int64 = 32_000_000

    @Test func aFullPhoneIsToldBeforeTheDownloadStartsRatherThanAfter() {
        let warning = DownloadReadiness.warning(
            sizeBytes: large,
            freeBytes: 210_000_000,
            metered: false
        )

        guard case let .notEnoughStorage(freeBytes, requiredBytes) = warning else {
            Issue.record("expected a storage warning, got \(String(describing: warning))")
            return
        }
        #expect(freeBytes == 210_000_000)
        #expect(requiredBytes > large)
    }

    @Test func storageOutranksTheRadioSoOnlyTheHardStopIsShown() {
        let warning = DownloadReadiness.warning(
            sizeBytes: large,
            freeBytes: 100_000_000,
            metered: true
        )

        if case .notEnoughStorage = warning {} else {
            Issue.record("storage must win over cellular")
        }
    }

    @Test func aLargeDownloadOnCellularIsWorthSaying() {
        let warning = DownloadReadiness.warning(
            sizeBytes: large,
            freeBytes: 8_000_000_000,
            metered: true
        )

        #expect(warning == .meteredConnection(sizeBytes: large))
    }

    @Test func theSmallModelTheWarningPointsAtDoesNotWarnAboutItself() {
        #expect(
            DownloadReadiness.warning(
                sizeBytes: small,
                freeBytes: 8_000_000_000,
                metered: true
            ) == nil
        )
    }

    @Test func wifiWithRoomToSpareSaysNothing() {
        #expect(
            DownloadReadiness.warning(
                sizeBytes: large,
                freeBytes: 8_000_000_000,
                metered: false
            ) == nil
        )
    }

    @Test func anUnreadableFreeSpaceReadingIsNotTreatedAsAFullDisk() {
        // The volume query returns 0 when it fails. Blocking every download on
        // that would be worse than the failure it is trying to prevent.
        #expect(
            DownloadReadiness.warning(sizeBytes: large, freeBytes: 0, metered: false) == nil
        )
    }

    @Test func aMissingModelFolderUsesItsExistingVolumeForCapacity() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-local-models-\(UUID().uuidString)", isDirectory: true)

        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(DownloadReadiness.availableStorageBytes(at: folder) > 0)
    }

    @Test func headroomScalesWithTheModelButNeverDropsBelowTheFloor() {
        #expect(DownloadReadiness.storageHeadroomBytes(small) == 128_000_000)
        #expect(DownloadReadiness.storageHeadroomBytes(large) == large / 4)
    }

    @Test func noEstimateIsClaimedWhileItWouldStillBeNoise() {
        #expect(
            DownloadReadiness.timeRemaining(
                downloadedBytes: 1_000_000, totalBytes: large, elapsed: 0.4
            ) == nil
        )
        #expect(
            DownloadReadiness.timeRemaining(
                downloadedBytes: 0, totalBytes: large, elapsed: 30
            ) == nil
        )
        #expect(
            DownloadReadiness.timeRemaining(
                downloadedBytes: large, totalBytes: large, elapsed: 30
            ) == nil
        )
    }

    @Test func aSettledEstimateReadsInPlainWords() {
        // 100 MB in 10s = 10 MB/s, 570 MB left, so a little under a minute.
        #expect(
            DownloadReadiness.timeRemaining(
                downloadedBytes: 100_000_000, totalBytes: large, elapsed: 10
            ) == "about a minute left"
        )
        #expect(
            DownloadReadiness.timeRemaining(
                downloadedBytes: large / 2, totalBytes: large, elapsed: 10
            ) == "about 10 seconds left"
        )
        #expect(
            DownloadReadiness.timeRemaining(
                downloadedBytes: large / 10, totalBytes: large, elapsed: 10
            ) == "about 2 minutes left"
        )
    }

    @Test func aVerySlowConnectionDoesNotPromiseAnHourlyFigure() {
        #expect(
            DownloadReadiness.timeRemaining(
                downloadedBytes: 1_000_000, totalBytes: large, elapsed: 60
            ) == nil
        )
    }

    @Test func theSizeLineSaysHowMuchHasActuallyMoved() {
        #expect(
            DownloadReadiness.sizeProgress(downloadedBytes: 254_000_000, totalBytes: large)
                == "254 MB of 670 MB"
        )
        #expect(DownloadReadiness.sizeProgress(downloadedBytes: 0, totalBytes: 0) == nil)
    }

    @Test func byteLabelsSwitchToGigabytesWhereTheyReadBetter() {
        #expect(DownloadReadiness.byteLabel(large) == "670 MB")
        #expect(DownloadReadiness.byteLabel(1_200_000_000) == "1.2 GB")
    }
}
