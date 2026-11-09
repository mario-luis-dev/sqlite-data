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
    /// Records older versions left on the server under a deleted record.
    ///
    /// Before a fetched deletion sent the deletions of what the device had under the deleted
    /// record (`FetchedDeletionTests`), those records stayed on the server, pointing at nothing,
    /// and every device that fetches them waits for their parent for good. A start deletes the
    /// ones known to be under a deleted record, and only those.
    @MainActor
    final class LeftoverRecordTests: BaseCloudKitTests, @unchecked Sendable {
      // * Another device creates a list with a reminder.
      // * Another device, on an older version, deletes the list; the reminder stays on the
      //   server.
      // * Local client fetches: the reminder waits for its list.
      // * The engine restarts.
      // => The reminder is deleted on the server, and no longer waits.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func leftoverUnderDeletedParentIsDeletedAtStart() async throws {
        try saveOnServer([listRecord(1), reminderRecord(1, listID: 1)])
        container.privateCloudDatabase.deleteRecordsLeavingChildren([
          RemindersList.recordID(for: 1)
        ])
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())
        #expect(try await unsyncedRecordNames() == [Reminder.recordName(for: 1)])

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(
          syncEngine.private.state.pendingRecordZoneChanges == [
            .deleteRecord(Reminder.recordID(for: 1))
          ]
        )
        #expect(try await unsyncedRecordNames() == [])
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(serverRecordNames() == [])
        #expect(try await metadataRecordNames() == [])
        try await userDatabase.read { db in
          try #expect(Reminder.all.fetchCount(db) == 0)
        }
      }

      // * Another device creates a record, a child under it, and a grandchild under the child.
      // * Another device, on an older version, deletes the record; the child and the grandchild
      //   stay on the server.
      // * Local client fetches: both wait.
      // * The engine restarts.
      // => Both are deleted on the server: the grandchild's parent is there, but it is under the
      //    child, which goes.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func grandchildUnderLeftoverIsDeleted() async throws {
        let modelA = CKRecord(recordType: ModelA.tableName, recordID: ModelA.recordID(for: 1))
        modelA.setValue(1, forKey: "id", at: 30)
        modelA.setValue(0, forKey: "count", at: 30)
        let modelB = CKRecord(recordType: ModelB.tableName, recordID: ModelB.recordID(for: 1))
        modelB.setValue(1, forKey: "id", at: 30)
        modelB.setValue(false, forKey: "isOn", at: 30)
        modelB.setValue(1, forKey: "modelAID", at: 30)
        modelB.parent = CKRecord.Reference(recordID: ModelA.recordID(for: 1), action: .none)
        let modelC = CKRecord(recordType: ModelC.tableName, recordID: ModelC.recordID(for: 1))
        modelC.setValue(1, forKey: "id", at: 30)
        modelC.setValue("Note", forKey: "title", at: 30)
        modelC.setValue(1, forKey: "modelBID", at: 30)
        modelC.parent = CKRecord.Reference(recordID: ModelB.recordID(for: 1), action: .none)
        try saveOnServer([modelA, modelB, modelC])
        container.privateCloudDatabase.deleteRecordsLeavingChildren([ModelA.recordID(for: 1)])
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())
        #expect(
          try await unsyncedRecordNames() == [
            ModelB.recordName(for: 1), ModelC.recordName(for: 1),
          ]
        )

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(
          Set(syncEngine.private.state.pendingRecordZoneChanges) == [
            .deleteRecord(ModelB.recordID(for: 1)),
            .deleteRecord(ModelC.recordID(for: 1)),
          ]
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(serverRecordNames() == [])
        #expect(try await unsyncedRecordNames() == [])
        #expect(try await metadataRecordNames() == [])
      }

      // * Another device creates a list with a reminder, and tags the reminder.
      // * Another device, on an older version, deletes the list; the reminder and its tagging
      //   stay on the server.
      // * Local client fetches: the reminder waits for its list, the tagging for the reminder.
      // * The engine restarts.
      // => The reminder and its tagging are deleted on the server. The tag stays.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func linkUnderLeftoverIsDeleted() async throws {
        try saveOnServer([
          listRecord(1), reminderRecord(1, listID: 1), tagRecord("home"),
          reminderTagRecord(1, reminderID: 1, tagID: "home"),
        ])
        container.privateCloudDatabase.deleteRecordsLeavingChildren([
          RemindersList.recordID(for: 1)
        ])
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())
        #expect(
          try await unsyncedRecordNames() == [
            Reminder.recordName(for: 1), ReminderTag.recordName(for: 1),
          ]
        )

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(
          Set(syncEngine.private.state.pendingRecordZoneChanges) == [
            .deleteRecord(Reminder.recordID(for: 1)),
            .deleteRecord(ReminderTag.recordID(for: 1)),
          ]
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(serverRecordNames() == [Tag.recordName(for: "home")])
        #expect(try await unsyncedRecordNames() == [])
        try await userDatabase.read { db in
          try #expect(Tag.all.fetchCount(db) == 1)
        }
      }

      // * Another device creates a list with a reminder, and tags the reminder with a tag whose
      //   own upload never reached the server (an iCloud account out of storage).
      // * Local client fetches: the tagging waits for its tag.
      // * The engine restarts.
      // => Nothing is deleted: the tag may still be on the other device, which would lose the
      //    tagging too. When the tag reaches the server at last, the tagging arrives with it.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func linkWaitingForUnsentRowIsKept() async throws {
        try saveOnServer([
          listRecord(1), reminderRecord(1, listID: 1),
          reminderTagRecord(1, reminderID: 1, tagID: "home"),
        ])
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())
        #expect(try await unsyncedRecordNames() == [ReminderTag.recordName(for: 1)])

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        #expect(
          serverRecordNames() == [
            RemindersList.recordName(for: 1), Reminder.recordName(for: 1),
            ReminderTag.recordName(for: 1),
          ]
        )
        #expect(try await unsyncedRecordNames() == [ReminderTag.recordName(for: 1)])

        try saveOnServer([tagRecord("home")])
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(
            ReminderTag.all.fetchAll(db) == [ReminderTag(id: 1, reminderID: 1, tagID: "home")]
          )
        }
        #expect(try await unsyncedRecordNames() == [])
      }

      // * Another device creates a parent and a child whose reference is cleared when the parent
      //   is deleted.
      // * Another device, on an older version, deletes the parent; the child stays on the server
      //   with its reference.
      // * Local client fetches: the child waits for its parent.
      // * The engine restarts.
      // => The child isn't deleted: it would have stayed, without its reference.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func childWhoseReferenceIsClearedIsKept() async throws {
        let parent = CKRecord(recordType: Parent.tableName, recordID: Parent.recordID(for: 1))
        parent.setValue(1, forKey: "id", at: 30)
        let child = CKRecord(
          recordType: ChildWithOnDeleteSetNull.tableName,
          recordID: ChildWithOnDeleteSetNull.recordID(for: 1)
        )
        child.setValue(1, forKey: "id", at: 30)
        child.setValue(1, forKey: "parentID", at: 30)
        child.parent = CKRecord.Reference(recordID: Parent.recordID(for: 1), action: .none)
        try saveOnServer([parent, child])
        container.privateCloudDatabase.deleteRecordsLeavingChildren([Parent.recordID(for: 1)])
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())
        #expect(try await unsyncedRecordNames() == [ChildWithOnDeleteSetNull.recordName(for: 1)])

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        #expect(serverRecordNames() == [ChildWithOnDeleteSetNull.recordName(for: 1)])
        #expect(try await unsyncedRecordNames() == [ChildWithOnDeleteSetNull.recordName(for: 1)])

        // NB: Another device deletes the child, which ends the wait.
        try deleteOnServer([ChildWithOnDeleteSetNull.recordID(for: 1)])
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())
        #expect(try await unsyncedRecordNames() == [])
      }

      // * Another device creates a list with a reminder.
      // * Local client has the reminder waiting, and hasn't fetched the list yet.
      // * The engine restarts.
      // => Nothing is deleted: the list is on the server, on its way. The next fetch brings it,
      //    and the reminder with it.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func waitingRecordWhoseParentIsOnServerIsKept() async throws {
        try saveOnServer([listRecord(1), reminderRecord(1, listID: 1)])
        try await markWaiting([Reminder.recordID(for: 1)])

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        #expect(
          serverRecordNames() == [RemindersList.recordName(for: 1), Reminder.recordName(for: 1)]
        )
        #expect(try await unsyncedRecordNames() == [Reminder.recordName(for: 1)])

        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(Reminder.all.fetchCount(db) == 1)
        }
        #expect(try await unsyncedRecordNames() == [])
      }

      // * Local client creates a list, and it is sent.
      // * Another device adds a reminder to the list.
      // * Another device, on an older version, deletes the list; the reminder stays on the
      //   server.
      // * Local client has the reminder waiting, and hasn't fetched the deletion yet.
      // * The engine restarts.
      // => Nothing is deleted while the list is on this device: what happens to it, and to what
      //    is under it, is the fetched deletion's to settle. Once that is fetched, the reminder
      //    is gone from the server too.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func waitingRecordWhoseParentIsOnDeviceIsKept() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try saveOnServer([reminderRecord(1, listID: 1)])
        container.privateCloudDatabase.deleteRecordsLeavingChildren([
          RemindersList.recordID(for: 1)
        ])
        try await markWaiting([Reminder.recordID(for: 1)])

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        #expect(serverRecordNames() == [Reminder.recordName(for: 1)])
        #expect(try await unsyncedRecordNames() == [Reminder.recordName(for: 1)])
        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 1)
        }

        // NB: The fetch deletes the list here, and the reminder waits for it again.
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())
        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
          try #expect(Reminder.all.fetchCount(db) == 0)
        }
        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        #expect(try await unsyncedRecordNames() == [Reminder.recordName(for: 1)])

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
        #expect(
          syncEngine.private.state.pendingRecordZoneChanges == [
            .deleteRecord(Reminder.recordID(for: 1))
          ]
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(serverRecordNames() == [])
        #expect(try await unsyncedRecordNames() == [])
      }

      // * Another device creates a list with a reminder.
      // * Another device, on an older version, deletes the list; the reminder stays on the
      //   server.
      // * Local client fetches: the reminder waits for its list.
      // * The engine restarts while iCloud can't be reached, then again once it can.
      // => Nothing is deleted unchecked; the next start deletes the reminder.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func leftoverWaitsWhenICloudCantBeChecked() async throws {
        try saveOnServer([listRecord(1), reminderRecord(1, listID: 1)])
        container.privateCloudDatabase.deleteRecordsLeavingChildren([
          RemindersList.recordID(for: 1)
        ])
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        container.privateCloudDatabase.state.withValue {
          $0.recordsLookupError = CKError(.networkUnavailable)
        }
        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        #expect(serverRecordNames() == [Reminder.recordName(for: 1)])
        #expect(try await unsyncedRecordNames() == [Reminder.recordName(for: 1)])

        container.privateCloudDatabase.state.withValue { $0.recordsLookupError = nil }
        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(serverRecordNames() == [])
        #expect(try await unsyncedRecordNames() == [])
      }

      /// The record names waiting on this device for a parent that hasn't arrived.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func unsyncedRecordNames() async throws -> Set<String> {
        try await syncEngine.metadatabase.read { db in
          Set(try UnsyncedRecordID.all.fetchAll(db).map(\.recordName))
        }
      }

      /// Puts records in the wait for a parent, as a fetch that delivered them before their parent
      /// does.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func markWaiting(_ recordIDs: [CKRecord.ID]) async throws {
        try await userDatabase.write { db in
          try UnsyncedRecordID
            .insert { recordIDs.map { UnsyncedRecordID(recordID: $0) } }
            .execute(db)
        }
      }

      private func listRecord(_ id: Int) -> CKRecord {
        let record = CKRecord(
          recordType: RemindersList.tableName,
          recordID: RemindersList.recordID(for: id)
        )
        record.setValue(id, forKey: "id", at: 30)
        record.setValue("Personal", forKey: "title", at: 30)
        return record
      }

      private func reminderRecord(_ id: Int, listID: Int) -> CKRecord {
        let record = CKRecord(recordType: Reminder.tableName, recordID: Reminder.recordID(for: id))
        record.setValue(id, forKey: "id", at: 30)
        record.setValue(false, forKey: "isCompleted", at: 30)
        record.setValue("Get milk", forKey: "title", at: 30)
        record.setValue(listID, forKey: "remindersListID", at: 30)
        record.parent = CKRecord.Reference(
          recordID: RemindersList.recordID(for: listID),
          action: .none
        )
        return record
      }

      private func tagRecord(_ title: String) -> CKRecord {
        let record = CKRecord(recordType: Tag.tableName, recordID: Tag.recordID(for: title))
        record.setValue(title, forKey: "title", at: 30)
        return record
      }

      /// A tagging, as SQLiteData sends it: with two foreign keys, it has no parent reference.
      private func reminderTagRecord(_ id: Int, reminderID: Int, tagID: String) -> CKRecord {
        let record = CKRecord(
          recordType: ReminderTag.tableName,
          recordID: ReminderTag.recordID(for: id)
        )
        record.setValue(id, forKey: "id", at: 30)
        record.setValue(reminderID, forKey: "reminderID", at: 30)
        record.setValue(tagID, forKey: "tagID", at: 30)
        return record
      }
    }
  }
#endif
