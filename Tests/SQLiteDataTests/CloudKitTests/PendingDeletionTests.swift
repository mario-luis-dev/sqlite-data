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
    @MainActor
    final class PendingDeletionTests: BaseCloudKitTests, @unchecked Sendable {
      // * Local client creates a list with a reminder, and both are sent.
      // * Local client deletes the list, which deletes the reminder too. The deletions are not
      //   sent yet (for example, CloudKit is throttling the device).
      // * A fetch delivers both records again: CloudKit returns this device's own earlier saves
      //   whenever its change token predates them.
      // => Both rows stay deleted and their deletions stay queued. Once the deletions are sent,
      //    the server and the device agree.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func fetchedOwnSaveDoesNotRestorePendingDeletion() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
            Reminder(id: 1, title: "Get milk", remindersListID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
        }

        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
          try #expect(Reminder.all.fetchCount(db) == 0)
        }
        #expect(
          try await deletedRecordNames() == [
            RemindersList.recordName(for: 1),
            Reminder.recordName(for: 1),
          ]
        )
        #expect(
          Set(syncEngine.private.state.pendingRecordZoneChanges) == [
            .deleteRecord(RemindersList.recordID(for: 1)),
            .deleteRecord(Reminder.recordID(for: 1)),
          ]
        )

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        assertInlineSnapshot(of: container, as: .customDump) {
          """
          MockCloudContainer(
            privateCloudDatabase: MockCloudDatabase(
              databaseScope: .private,
              storage: []
            ),
            sharedCloudDatabase: MockCloudDatabase(
              databaseScope: .shared,
              storage: []
            )
          )
          """
        }

        // NB: The next fetch delivers the server's deletions of both records.
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
          try #expect(Reminder.all.fetchCount(db) == 0)
        }
      }

      // * Local client creates a list, and it is sent.
      // * Another device renames the list.
      // * Local client deletes the list, and receives the rename before its deletion is sent.
      // => The list stays deleted, and sending the deletion deletes it on the server too.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func fetchedRemoteEditDoesNotRestorePendingDeletion() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let record = try syncEngine.private.database.record(for: RemindersList.recordID(for: 1))
        record.setValue("Business", forKey: "title", at: 30)
        let modification = try syncEngine.modifyRecords(scope: .private, saving: [record])

        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
        }
        await modification.notify()

        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
        }
        #expect(try await deletedRecordNames() == [RemindersList.recordName(for: 1)])
        #expect(
          Set(syncEngine.private.state.pendingRecordZoneChanges) == [
            .deleteRecord(RemindersList.recordID(for: 1))
          ]
        )

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        assertInlineSnapshot(of: container, as: .customDump) {
          """
          MockCloudContainer(
            privateCloudDatabase: MockCloudDatabase(
              databaseScope: .private,
              storage: []
            ),
            sharedCloudDatabase: MockCloudDatabase(
              databaseScope: .shared,
              storage: []
            )
          )
          """
        }
        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
        }
      }

      // * Local client creates a list with a reminder, and both are sent.
      // * Another device moves the reminder to a new list. Local client receives the reminder
      //   before the new list, so it cannot apply it yet and queues it to be fetched again.
      // * Local client deletes the reminder.
      // * Local client receives the new list, and fetches the queued reminder again before its
      //   deletion is sent.
      // => The reminder stays deleted, and sending the deletion deletes it on the server too.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func unsyncedRecordRetryDoesNotRestorePendingDeletion() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
            Reminder(id: 1, title: "Get milk", remindersListID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let remindersListRecord = CKRecord(
          recordType: RemindersList.tableName,
          recordID: RemindersList.recordID(for: 2)
        )
        remindersListRecord.setValue(2, forKey: "id", at: 30)
        remindersListRecord.setValue("Business", forKey: "title", at: 30)
        let remindersListModification = try syncEngine.modifyRecords(
          scope: .private,
          saving: [remindersListRecord]
        )

        let reminderRecord = try syncEngine.private.database.record(for: Reminder.recordID(for: 1))
        reminderRecord.setValue(2, forKey: "remindersListID", at: 30)
        reminderRecord.parent = CKRecord.Reference(
          recordID: RemindersList.recordID(for: 2),
          action: .none
        )
        try await syncEngine.modifyRecords(scope: .private, saving: [reminderRecord]).notify()

        try await userDatabase.userWrite { db in
          try Reminder.find(1).delete().execute(db)
        }
        await remindersListModification.notify()

        try await userDatabase.read { db in
          try #expect(Reminder.all.fetchCount(db) == 0)
          try #expect(
            RemindersList.all.fetchAll(db) == [
              RemindersList(id: 1, title: "Personal"),
              RemindersList(id: 2, title: "Business"),
            ]
          )
        }
        #expect(try await deletedRecordNames() == [Reminder.recordName(for: 1)])
        #expect(
          Set(syncEngine.private.state.pendingRecordZoneChanges) == [
            .deleteRecord(Reminder.recordID(for: 1))
          ]
        )

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        assertInlineSnapshot(of: container, as: .customDump) {
          """
          MockCloudContainer(
            privateCloudDatabase: MockCloudDatabase(
              databaseScope: .private,
              storage: [
                [0]: CKRecord(
                  recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__),
                  recordType: "remindersLists",
                  parent: nil,
                  share: nil,
                  id: 1,
                  title: "Personal"
                ),
                [1]: CKRecord(
                  recordID: CKRecord.ID(2:remindersLists/zone/__defaultOwner__),
                  recordType: "remindersLists",
                  parent: nil,
                  share: nil,
                  id: 2,
                  title: "Business"
                )
              ]
            ),
            sharedCloudDatabase: MockCloudDatabase(
              databaseScope: .shared,
              storage: []
            )
          )
          """
        }

        // NB: The next fetch delivers the server's deletion of the reminder, and the queued
        //     reminder is no longer on the server.
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(Reminder.all.fetchCount(db) == 0)
        }
      }

      // * Local client creates a list, and it is sent.
      // * Another device renames the list, and local client renames it too.
      // * Local client sends its rename, and deletes the list before the server answers that
      //   the list changed on the server.
      // => The list stays deleted, and sending the deletion deletes it on the server too.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func serverRecordChangedDoesNotRestorePendingDeletion() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        let record = try syncEngine.private.database.record(for: RemindersList.recordID(for: 1))
        record.setValue("Business", forKey: "title", at: 30)
        _ = try syncEngine.modifyRecords(scope: .private, saving: [record])

        try await withDependencies {
          $0.currentTime.now += 60
        } operation: {
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).update { $0.title = "Family" }.execute(db)
          }
        }
        let sentChanges = try await syncEngine.sendPendingRecordZoneChanges(scope: .private)
        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
        }
        await sentChanges.receive()

        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
        }
        #expect(try await deletedRecordNames() == [RemindersList.recordName(for: 1)])
        // NB: The failed save is not queued again: CKSyncEngine discards a pending deletion when a
        //     save of the same record is added after it.
        #expect(
          Set(syncEngine.private.state.pendingRecordZoneChanges) == [
            .deleteRecord(RemindersList.recordID(for: 1))
          ]
        )

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        assertInlineSnapshot(of: container, as: .customDump) {
          """
          MockCloudContainer(
            privateCloudDatabase: MockCloudDatabase(
              databaseScope: .private,
              storage: []
            ),
            sharedCloudDatabase: MockCloudDatabase(
              databaseScope: .shared,
              storage: []
            )
          )
          """
        }
        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
        }
      }

      // * Local client creates a list, and it is sent.
      // * Local client deletes the list. A batch with the deletion is built, but CloudKit has not
      //   confirmed it yet (the send is in flight, throttled, or the app was closed).
      // * A fetch delivers the list again: this device's own earlier save.
      // => The list stays deleted, and its deletion stays queued. Once CloudKit confirms the
      //    deletion, its metadata goes, and fetching the server's deletion leaves nothing behind.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func fetchedOwnSaveDoesNotRestoreUnconfirmedDeletion() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
        }
        let batch = await syncEngine.nextRecordZoneChangeBatch(syncEngine: syncEngine.private)
        #expect(batch?.recordIDsToDelete == [RemindersList.recordID(for: 1)])
        #expect(try await deletedRecordNames() == [RemindersList.recordName(for: 1)])

        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
        }
        #expect(try await deletedRecordNames() == [RemindersList.recordName(for: 1)])
        #expect(
          syncEngine.private.state.pendingRecordZoneChanges == [
            .deleteRecord(RemindersList.recordID(for: 1))
          ]
        )

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        assertInlineSnapshot(of: container, as: .customDump) {
          """
          MockCloudContainer(
            privateCloudDatabase: MockCloudDatabase(
              databaseScope: .private,
              storage: []
            ),
            sharedCloudDatabase: MockCloudDatabase(
              databaseScope: .shared,
              storage: []
            )
          )
          """
        }
        #expect(try await metadataCount() == 0)

        // NB: The next fetch delivers the server's deletion of the list.
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
        }
        #expect(try await metadataCount() == 0)
      }

      // * Local client creates a list, and it is sent.
      // * Local client deletes the list, and sending the deletion fails with an error CloudKit
      //   retries (CKSyncEngine keeps the deletion queued).
      // * A fetch delivers the list again: this device's own earlier save.
      // => The list stays deleted, and the retried deletion deletes it on the server too.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func fetchedOwnSaveDoesNotRestoreDeletionAfterRetryableFailure() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
        }
        _ = await syncEngine.nextRecordZoneChangeBatch(syncEngine: syncEngine.private)
        // NB: CKSyncEngine keeps a change that failed with a retryable error in its pending
        //     changes, and the mock never removed it.
        await syncEngine.handleEvent(
          .sentRecordZoneChanges(
            savedRecords: [],
            failedRecordSaves: [],
            deletedRecordIDs: [],
            failedRecordDeletes: [RemindersList.recordID(for: 1): CKError(.networkFailure)]
          ),
          syncEngine: syncEngine.private
        )
        #expect(try await deletedRecordNames() == [RemindersList.recordName(for: 1)])

        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
        }
        #expect(
          syncEngine.private.state.pendingRecordZoneChanges == [
            .deleteRecord(RemindersList.recordID(for: 1))
          ]
        )

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        assertInlineSnapshot(of: container, as: .customDump) {
          """
          MockCloudContainer(
            privateCloudDatabase: MockCloudDatabase(
              databaseScope: .private,
              storage: []
            ),
            sharedCloudDatabase: MockCloudDatabase(
              databaseScope: .shared,
              storage: []
            )
          )
          """
        }
        #expect(try await metadataCount() == 0)

        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
        }
        #expect(try await metadataCount() == 0)
      }

      // * Local client creates a list, and it is sent.
      // * Local client deletes the list, and CloudKit refuses the deletion for a reason it does not
      //   retry, so CKSyncEngine drops it.
      // => The deletion's metadata goes with it, so the list is not cut off from the server: the
      //    next fetch of the list brings it back.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func droppedDeletionDoesNotKeepMetadata() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
        }
        _ = await syncEngine.nextRecordZoneChangeBatch(syncEngine: syncEngine.private)
        syncEngine.private.state.remove(
          pendingRecordZoneChanges: [.deleteRecord(RemindersList.recordID(for: 1))]
        )
        await syncEngine.handleEvent(
          .sentRecordZoneChanges(
            savedRecords: [],
            failedRecordSaves: [],
            deletedRecordIDs: [],
            failedRecordDeletes: [RemindersList.recordID(for: 1): CKError(.serverRejectedRequest)]
          ),
          syncEngine: syncEngine.private
        )

        #expect(try await metadataCount() == 0)

        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchAll(db) == [RemindersList(id: 1, title: "Personal")])
        }
      }

      // * Local client creates a list, and it is sent.
      // * Local client deletes the list, and the deletion is sent.
      // * Before CloudKit confirms the deletion, local client creates the list again with the same
      //   primary key.
      // => Once the deletion is confirmed, the new list is uploaded.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func rowCreatedAgainBeforeDeletionIsConfirmedIsUploaded() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
        }
        let sentChanges = try await syncEngine.sendPendingRecordZoneChanges(scope: .private)
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Business")
          }
        }
        await sentChanges.receive()

        #expect(try await deletedRecordNames() == [])
        #expect(
          syncEngine.private.state.pendingRecordZoneChanges == [
            .saveRecord(RemindersList.recordID(for: 1))
          ]
        )

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        assertInlineSnapshot(of: container, as: .customDump) {
          """
          MockCloudContainer(
            privateCloudDatabase: MockCloudDatabase(
              databaseScope: .private,
              storage: [
                [0]: CKRecord(
                  recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__),
                  recordType: "remindersLists",
                  parent: nil,
                  share: nil,
                  id: 1,
                  title: "Business"
                )
              ]
            ),
            sharedCloudDatabase: MockCloudDatabase(
              databaseScope: .shared,
              storage: []
            )
          )
          """
        }
        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchAll(db) == [RemindersList(id: 1, title: "Business")])
        }
      }

      /// The number of rows in the metadata table.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func metadataCount() async throws -> Int {
        try await syncEngine.metadatabase.read { db in
          try SyncMetadata.count().fetchOne(db) ?? 0
        }
      }

      /// The record names whose local deletion is still waiting to be sent or confirmed.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func deletedRecordNames() async throws -> Set<String> {
        try await syncEngine.metadatabase.read { db in
          Set(try SyncMetadata.where(\._isDeleted).select(\.recordName).fetchAll(db))
        }
      }
    }
  }
#endif
