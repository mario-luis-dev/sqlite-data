#if canImport(CloudKit)
  import CloudKit
  import CustomDump
  import Dependencies
  import InlineSnapshotTesting
  import SQLiteData
  import SQLiteDataTestSupport
  import SnapshotTestingCustomDump
  import Testing

  extension BaseCloudKitTests {
    /// Records under a record another device deleted, which this device added there.
    ///
    /// The device that deletes a record sends the deletions of what it has under it. A link
    /// another device added under it, and the deleting device never fetched, stays on the server:
    /// a link points at its rows only through plain values, which CloudKit can't check. When this
    /// device fetches the deletion, SQLite deletes those rows here too, or clears their reference,
    /// and the server must follow: otherwise the records stay there pointing at nothing, and every
    /// device that fetches them waits for their parent for good. CloudKit refuses to delete a
    /// record while another one points at it as its parent, so the tests with a reminder under a
    /// list leave it there with `deleteRecordsLeavingChildren`.
    @MainActor
    final class FetchedDeletionTests: BaseCloudKitTests, @unchecked Sendable {
      // * Local client creates a list, and it is sent.
      // * Local client adds a reminder to the list, and it is sent.
      // * Another device, which never fetched the reminder, deletes the list.
      // * Local client fetches the deletion.
      // => The reminder is deleted on this device and on the server.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func fetchedDeletionOfParentDeletesChildAddedHere() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await userDatabase.userWrite { db in
          try db.seed {
            Reminder(id: 1, title: "Get milk", remindersListID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        container.privateCloudDatabase.deleteRecordsLeavingChildren([
          RemindersList.recordID(for: 1)
        ])
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
          try #expect(Reminder.all.fetchCount(db) == 0)
        }
        #expect(
          syncEngine.private.state.pendingRecordZoneChanges == [
            .deleteRecord(Reminder.recordID(for: 1))
          ]
        )
        #expect(try await flaggedRecordNames() == [Reminder.recordName(for: 1)])

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(serverRecordNames() == [])
        #expect(try await metadataRecordNames() == [])
      }

      // * Local client creates a list with a reminder and a tag, and they are sent.
      // * Local client tags the reminder, and the tagging is sent.
      // * Another device, which never fetched the tagging, deletes the reminder. CloudKit lets it:
      //   the tagging points at the reminder only through a plain value.
      // * Local client fetches the deletion.
      // => The tagging is deleted on this device and on the server, and nothing waits. The tag
      //    stays.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func fetchedDeletionOfReminderDeletesTaggingAddedHere() async throws {
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
          try #expect(Reminder.all.fetchCount(db) == 0)
          try #expect(ReminderTag.all.fetchCount(db) == 0)
          try #expect(Tag.all.fetchCount(db) == 1)
        }
        #expect(
          syncEngine.private.state.pendingRecordZoneChanges == [
            .deleteRecord(ReminderTag.recordID(for: 1))
          ]
        )
        #expect(try await unsyncedRecordNames() == [])

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(
          serverRecordNames() == [RemindersList.recordName(for: 1), Tag.recordName(for: "home")]
        )
        #expect(
          try await metadataRecordNames() == [
            RemindersList.recordName(for: 1), Tag.recordName(for: "home"),
          ]
        )
      }

      // * Local client creates a list with a reminder, and both are sent.
      // * Another device deletes the list and the reminder.
      // * Local client fetches the deletions.
      // => Both are gone, and nothing more is sent.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func fetchedDeletionOfParentAndChildSendsNothingMore() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
            Reminder(id: 1, title: "Get milk", remindersListID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try deleteOnServer([Reminder.recordID(for: 1), RemindersList.recordID(for: 1)])
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
          try #expect(Reminder.all.fetchCount(db) == 0)
        }
        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        #expect(serverRecordNames() == [])
        #expect(try await metadataRecordNames() == [])
      }

      // * Local client creates a record, a child under it, and a grandchild under the child, and
      //   all of them are sent; the grandchild after the others.
      // * Another device, which never fetched the grandchild, deletes the record and the child.
      // * Local client fetches the deletions.
      // => The grandchild is deleted on this device and on the server.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func fetchedDeletionOfGrandparentDeletesGrandchildAddedHere() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            ModelA.Draft(id: 1)
            ModelB(id: 1, modelAID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await userDatabase.userWrite { db in
          try db.seed {
            ModelC(id: 1, title: "Note", modelBID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        container.privateCloudDatabase.deleteRecordsLeavingChildren([
          ModelB.recordID(for: 1), ModelA.recordID(for: 1),
        ])
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        #expect(
          syncEngine.private.state.pendingRecordZoneChanges == [
            .deleteRecord(ModelC.recordID(for: 1))
          ]
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.read { db in
          try #expect(ModelA.all.fetchCount(db) == 0)
          try #expect(ModelB.all.fetchCount(db) == 0)
          try #expect(ModelC.all.fetchCount(db) == 0)
        }
        #expect(serverRecordNames() == [])
        #expect(try await metadataRecordNames() == [])
      }

      // * Local client creates a parent and a child whose reference is cleared when the parent is
      //   deleted, and both are sent.
      // * Another device, which never fetched the child, deletes the parent.
      // * Local client fetches the deletion.
      // => The child stays, and is sent without its reference, as the other device would have
      //    sent it had it known the child.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func fetchedDeletionOfParentSendsChildWithReferenceCleared() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            Parent(id: 1)
            ChildWithOnDeleteSetNull(id: 1, parentID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        container.privateCloudDatabase.deleteRecordsLeavingChildren([Parent.recordID(for: 1)])
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(
            ChildWithOnDeleteSetNull.all.fetchAll(db)
              == [ChildWithOnDeleteSetNull(id: 1, parentID: nil)]
          )
        }
        #expect(
          syncEngine.private.state.pendingRecordZoneChanges == [
            .saveRecord(ChildWithOnDeleteSetNull.recordID(for: 1))
          ]
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let childRecord = serverRecord(ChildWithOnDeleteSetNull.recordID(for: 1))
        #expect(childRecord != nil)
        #expect(childRecord?.encryptedValues["parentID"] == nil)
        #expect(childRecord?.parent == nil)
        #expect(serverRecordNames() == [ChildWithOnDeleteSetNull.recordName(for: 1)])
      }

      // * Local client creates two lists and a reminder in the first one, and all are sent.
      // * Another device moves the reminder to the second list, and deletes the first list.
      // * Local client fetches the deletion before the move: CloudKit can deliver them in
      //   different pages.
      // => The reminder isn't deleted: it is written back from the server, in the second list.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func fetchedDeletionBeforeMoveKeepsMovedChild() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
            RemindersList(id: 2, title: "Business")
            Reminder(id: 1, title: "Get milk", remindersListID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let reminderRecord = try container.privateCloudDatabase.record(
          for: Reminder.recordID(for: 1)
        )
        reminderRecord.setValue(2, forKey: "remindersListID", at: 30)
        reminderRecord.parent = CKRecord.Reference(
          recordID: RemindersList.recordID(for: 2),
          action: .none
        )
        try saveOnServer([reminderRecord])
        try deleteOnServer([RemindersList.recordID(for: 1)])

        await syncEngine.handleFetchedRecordZoneChanges(
          deletions: [(RemindersList.recordID(for: 1), RemindersList.tableName)],
          syncEngine: syncEngine.private
        )

        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchAll(db).map(\.id) == [2])
          try #expect(
            Reminder.all.fetchAll(db)
              == [Reminder(id: 1, title: "Get milk", remindersListID: 2)]
          )
        }
        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        #expect(try await flaggedRecordNames() == [])

        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(Reminder.find(1).fetchOne(db)?.remindersListID == 2)
        }
        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        #expect(
          serverRecordNames() == [RemindersList.recordName(for: 2), Reminder.recordName(for: 1)]
        )
      }

      // * Local client creates two lists and a reminder in the first one, and all are sent.
      // * Another device moves the reminder to the second list, and deletes the first list.
      // * Local client fetches both in one page.
      // => The reminder stays, in the second list, and nothing is sent.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func fetchedDeletionWithMoveInSamePageKeepsMovedChild() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
            RemindersList(id: 2, title: "Business")
            Reminder(id: 1, title: "Get milk", remindersListID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let reminderRecord = try container.privateCloudDatabase.record(
          for: Reminder.recordID(for: 1)
        )
        reminderRecord.setValue(2, forKey: "remindersListID", at: 30)
        reminderRecord.parent = CKRecord.Reference(
          recordID: RemindersList.recordID(for: 2),
          action: .none
        )
        try saveOnServer([reminderRecord])
        try deleteOnServer([RemindersList.recordID(for: 1)])
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(
            Reminder.all.fetchAll(db)
              == [Reminder(id: 1, title: "Get milk", remindersListID: 2)]
          )
        }
        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        #expect(try await flaggedRecordNames() == [])
        #expect(
          serverRecordNames() == [RemindersList.recordName(for: 2), Reminder.recordName(for: 1)]
        )
      }

      // * Local client creates a list, and it is sent.
      // * Local client adds a reminder to the list, and it is sent.
      // * Another device, which never fetched the reminder, deletes the list.
      // * Local client fetches the deletion, and can't reach iCloud to check the reminder.
      // => Nothing is sent unchecked: the reminder could have moved to another list. It waits
      //    for its list, as a record whose parent hasn't arrived does, until the next fetch.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func fetchedDeletionSendsNothingWhenICloudCantBeChecked() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await userDatabase.userWrite { db in
          try db.seed {
            Reminder(id: 1, title: "Get milk", remindersListID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        container.privateCloudDatabase.deleteRecordsLeavingChildren([
          RemindersList.recordID(for: 1)
        ])
        container.privateCloudDatabase.state.withValue {
          $0.recordsLookupError = CKError(.networkUnavailable)
        }
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(Reminder.all.fetchCount(db) == 0)
        }
        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        #expect(serverRecordNames() == [Reminder.recordName(for: 1)])
        #expect(try await unsyncedRecordNames() == [Reminder.recordName(for: 1)])

        // NB: Another device deletes the reminder, which ends the wait.
        container.privateCloudDatabase.state.withValue { $0.recordsLookupError = nil }
        try deleteOnServer([Reminder.recordID(for: 1)])
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        #expect(try await unsyncedRecordNames() == [])
      }

      // * Local client creates a list and a reminder in it. Only the list is sent.
      // * Another device deletes the list.
      // * Local client fetches the deletion.
      // => The reminder, which never reached the server, is gone, and nothing is sent for it.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func fetchedDeletionOfParentSendsNothingForUnsentChild() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await userDatabase.userWrite { db in
          try db.seed {
            Reminder(id: 1, title: "Get milk", remindersListID: 1)
          }
        }

        try deleteOnServer([RemindersList.recordID(for: 1)])
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.read { db in
          try #expect(Reminder.all.fetchCount(db) == 0)
        }
        #expect(serverRecordNames() == [])
        #expect(serverDeletions() == [RemindersList.recordName(for: 1)])
        #expect(try await metadataRecordNames() == [])
      }

      /// The record names waiting on this device for a parent that hasn't arrived.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func unsyncedRecordNames() async throws -> Set<String> {
        try await syncEngine.metadatabase.read { db in
          Set(try UnsyncedRecordID.all.fetchAll(db).map(\.recordName))
        }
      }
    }
  }
#endif
