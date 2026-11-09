#if canImport(CloudKit)
  import CloudKit
  import Dependencies
  import SQLiteData
  import SQLiteDataTestSupport
  import Testing

  extension BaseCloudKitTests {
    @MainActor
    final class FetchedDeletionTests: BaseCloudKitTests, @unchecked Sendable {
      // * This device creates a list with a reminder and a tag, and they are sent.
      // * This device tags the reminder, and the tagging is sent.
      // * Another device, which never fetched the tagging, deletes the reminder. CloudKit allows it:
      //   a tagging has two foreign keys, so it has no parent reference pointing at the reminder.
      // * This device fetches the deletion, and SQLite deletes the tagging here too
      //   (ON DELETE CASCADE).
      // => The tagging should be deleted on the server too. Instead it stays there, pointing at a
      //    reminder that no longer exists, and every device that fetches it waits for that
      //    reminder forever (unsyncedRecordIDs).
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func fetchedDeletionOfReminderDeletesTaggingOnServer() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
            Reminder(id: 1, title: "Get milk", remindersListID: 1)
            Tag(title: "home")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await userDatabase.userWrite { db in
          try db.seed {
            ReminderTag(id: 1, reminderID: 1, tagID: "home")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        _ = try container.privateCloudDatabase.modifyRecords(
          deleting: [Reminder.recordID(for: 1)]
        )
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(ReminderTag.all.fetchCount(db) == 0)
        }
        #expect(
          syncEngine.private.state.pendingRecordZoneChanges == [
            .deleteRecord(ReminderTag.recordID(for: 1))
          ]
        )
        if !syncEngine.private.state.pendingRecordZoneChanges.isEmpty {
          try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        }
        #expect(
          (try? container.privateCloudDatabase.record(for: ReminderTag.recordID(for: 1))) == nil,
          "The tagging is still on the server, pointing at a reminder that is gone."
        )
        try await syncEngine.metadatabase.read { db in
          try #expect(
            UnsyncedRecordID.fetchCount(db) == 0,
            "The tagging came back in the same fetch and now waits for the deleted reminder."
          )
        }
      }
    }
  }
#endif
