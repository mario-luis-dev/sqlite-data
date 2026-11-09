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
    /// A local deletion whose metadata is still flagged `_isDeleted` hasn't been confirmed by
    /// CloudKit. When the engine starts without it in its queue, it must be queued again, or the
    /// record stays on the server for good while the row is gone from the device.
    ///
    /// The mocks start every engine from an empty state. That is what CKSyncEngine does when its
    /// saved state is lost, or was saved before the deletion was queued. Seen on a device: after
    /// iCloud was switched off while CloudKit throttled the device, the next start had 2,192
    /// deletions flagged in the metadata and none in the queue.
    @MainActor
    final class LostDeletionTests: BaseCloudKitTests, @unchecked Sendable {
      // * Local client creates a list with a reminder, and both are sent.
      // * Local client deletes the list, which deletes the reminder too.
      // * The engine restarts without the deletions in its queue.
      // * A fetch delivers both records again: this device's own earlier saves.
      // => Both rows stay deleted, the start queues both deletions again, and sending them
      //    deletes both records on the server.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func deletionLostFromQueueIsSentAtNextStart() async throws {
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

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(
          Set(syncEngine.private.state.pendingRecordZoneChanges) == [
            .deleteRecord(RemindersList.recordID(for: 1)),
            .deleteRecord(Reminder.recordID(for: 1)),
          ]
        )

        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
          try #expect(Reminder.all.fetchCount(db) == 0)
        }

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
        #expect(try await deletedRecordNames() == [])
      }

      // * Local client creates a list and deletes it before it is sent.
      // * The engine restarts without the deletion in its queue.
      // => Nothing is sent, since the server never had the list, and no metadata is left behind.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func neverSentDeletionLostFromQueueLeavesNothingBehind() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
        }

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)

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
      }

      // * Local client creates a list, and it is sent.
      // * Local client deletes the list, and the engine stops before the deletion is sent.
      // * While the engine is stopped, local client creates a list with the same id.
      // * The engine restarts without the deletion in its queue.
      // => The new list is sent as an edit of the old one, as when it is created again before
      //    the deletion is sent while the engine runs
      //    (`PendingDeletionTests.rowCreatedAgainBeforeDeletionIsSentReplacesTheDeletion`). The
      //    server record is never deleted: every other device would then delete its list.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func rowCreatedAgainWhileStoppedIsUploadedInPlace() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
        }
        syncEngine.stop()

        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Business")
          }
        }
        try await Task.sleep(for: .seconds(0.5))

        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
        #expect(
          syncEngine.private.state.pendingRecordZoneChanges == [
            .saveRecord(RemindersList.recordID(for: 1))
          ]
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        #expect(serverDeletions() == [])

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
        #expect(try await deletedRecordNames() == [])
      }

      // * Local client shares a list with a reminder, and all of it is sent.
      // * Local client deletes the list, which deletes the reminder too.
      // * The engine restarts without the deletions in its queue.
      // => The start queues the deletions of the list, its share and the reminder again, and
      //    sending them deletes all three on the server.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func sharedRootDeletionLostFromQueueDeletesItsShare() async throws {
        let remindersList = RemindersList(id: 1, title: "Personal")
        try await userDatabase.userWrite { db in
          try db.seed {
            remindersList
            Reminder(id: 1, remindersListID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let _ = try await syncEngine.share(record: remindersList, configure: { _ in })

        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
        }

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(
          Set(syncEngine.private.state.pendingRecordZoneChanges) == [
            .deleteRecord(RemindersList.recordID(for: 1)),
            .deleteRecord(
              CKRecord.ID(
                recordName: "share-\(RemindersList.recordID(for: 1).recordName)",
                zoneID: syncEngine.defaultZone.zoneID
              )
            ),
            .deleteRecord(Reminder.recordID(for: 1)),
          ]
        )
        #expect(syncEngine.shared.state.pendingRecordZoneChanges.isEmpty)

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
        #expect(try await deletedRecordNames() == [])
      }

      // * Another user shares a list with a reminder with this user.
      // * Local client deletes the reminder.
      // * The engine restarts without the deletion in its queue.
      // => The start queues the deletion again on the shared database, and sending it deletes
      //    the reminder there while the list and its share stay.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func deletionInSharedZoneLostFromQueueIsSentToSharedDatabase() async throws {
        let externalZone = CKRecordZone(
          zoneID: CKRecordZone.ID(
            zoneName: "external.zone",
            ownerName: "external.owner"
          )
        )
        try await syncEngine.modifyRecordZones(scope: .shared, saving: [externalZone]).notify()

        let remindersListRecord = CKRecord(
          recordType: RemindersList.tableName,
          recordID: RemindersList.recordID(for: 1, zoneID: externalZone.zoneID)
        )
        remindersListRecord.setValue(1, forKey: "id", at: now)
        remindersListRecord.setValue("Personal", forKey: "title", at: now)
        let reminderRecord = CKRecord(
          recordType: Reminder.tableName,
          recordID: Reminder.recordID(for: 1, zoneID: externalZone.zoneID)
        )
        reminderRecord.setValue(1, forKey: "id", at: now)
        reminderRecord.setValue(false, forKey: "isCompleted", at: now)
        reminderRecord.setValue("Get milk", forKey: "title", at: now)
        reminderRecord.setValue(1, forKey: "remindersListID", at: now)
        reminderRecord.parent = CKRecord.Reference(record: remindersListRecord, action: .none)
        let share = CKShare(
          rootRecord: remindersListRecord,
          shareID: CKRecord.ID(
            recordName: "share-\(remindersListRecord.recordID.recordName)",
            zoneID: remindersListRecord.recordID.zoneID
          )
        )
        try await syncEngine.modifyRecords(
          scope: .shared,
          saving: [remindersListRecord, reminderRecord, share]
        ).notify()

        try await withDependencies {
          $0.currentTime.now += 60
        } operation: {
          try await userDatabase.userWrite { db in
            try Reminder.find(1).delete().execute(db)
          }
        }

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(
          syncEngine.shared.state.pendingRecordZoneChanges == [
            .deleteRecord(Reminder.recordID(for: 1, zoneID: externalZone.zoneID))
          ]
        )
        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)

        try await syncEngine.processPendingRecordZoneChanges(scope: .shared)

        assertInlineSnapshot(of: container, as: .customDump) {
          """
          MockCloudContainer(
            privateCloudDatabase: MockCloudDatabase(
              databaseScope: .private,
              storage: []
            ),
            sharedCloudDatabase: MockCloudDatabase(
              databaseScope: .shared,
              storage: [
                [0]: CKRecord(
                  recordID: CKRecord.ID(share-1:remindersLists/external.zone/external.owner),
                  recordType: "cloudkit.share",
                  parent: nil,
                  share: nil,
                  cloudkit.title: nil
                ),
                [1]: CKRecord(
                  recordID: CKRecord.ID(1:remindersLists/external.zone/external.owner),
                  recordType: "remindersLists",
                  parent: nil,
                  share: CKReference(recordID: CKRecord.ID(share-1:remindersLists/external.zone/external.owner)),
                  id: 1,
                  title: "Personal"
                )
              ]
            )
          )
          """
        }
        #expect(try await deletedRecordNames() == [])
      }

      // * Local client creates a list, and it is sent.
      // * Local client adds a reminder to the list, and it is sent. CloudKit changes the list's
      //   version when a record starts pointing at it, without sending the list back.
      // * Local client deletes the list, which deletes the reminder too.
      // * The engine restarts without the deletions in its queue.
      // => Both deletions are sent: nothing changed on another device, even though the server's
      //    version of the list is newer than the one this device knows.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func lostDeletionOfParentWhoseChildThisDeviceAddedIsSent() async throws {
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

        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
        }

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(
          Set(syncEngine.private.state.pendingRecordZoneChanges) == [
            .deleteRecord(RemindersList.recordID(for: 1)),
            .deleteRecord(Reminder.recordID(for: 1)),
          ]
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(serverRecordNames() == [])
        #expect(try await deletedRecordNames() == [])
      }

      // * Local client creates a list, and it is sent.
      // * Local client deletes the list.
      // * Another device renames the list. This device hasn't fetched the rename.
      // * The engine restarts without the deletion in its queue.
      // => The deletion is sent all the same: the person deleted the list, and a deletion wins
      //    over an edit made elsewhere. The list is gone on this device and on the server.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func lostDeletionOfRecordEditedElsewhereIsSent() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
        }
        let record = try container.privateCloudDatabase.record(
          for: RemindersList.recordID(for: 1)
        )
        record.setValue("Business", forKey: "title", at: 30)
        try saveOnServer([record])

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(
          syncEngine.private.state.pendingRecordZoneChanges == [
            .deleteRecord(RemindersList.recordID(for: 1))
          ]
        )

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
        }
        #expect(serverRecordNames() == [])
        #expect(try await deletedRecordNames() == [])
        #expect(try await metadataCount() == 0)
      }

      // * Local client creates a list, and it is sent.
      // * Local client deletes the list.
      // * Another device adds a reminder to the list. This device hasn't fetched it.
      // * The engine restarts without the deletion in its queue.
      // => The deletion is sent, and the reminder goes with it: CloudKit refuses to delete the
      //    list while the reminder points at it as its parent.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func lostDeletionOfParentWithChildAddedElsewhereDeletesTheChild() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
        }
        let reminderRecord = CKRecord(
          recordType: Reminder.tableName,
          recordID: Reminder.recordID(for: 1)
        )
        reminderRecord.setValue(1, forKey: "id", at: 30)
        reminderRecord.setValue(false, forKey: "isCompleted", at: 30)
        reminderRecord.setValue("Get milk", forKey: "title", at: 30)
        reminderRecord.setValue(1, forKey: "remindersListID", at: 30)
        reminderRecord.parent = CKRecord.Reference(
          recordID: RemindersList.recordID(for: 1),
          action: .none
        )
        try saveOnServer([reminderRecord])

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(
          Set(syncEngine.private.state.pendingRecordZoneChanges) == [
            .deleteRecord(RemindersList.recordID(for: 1)),
            .deleteRecord(Reminder.recordID(for: 1)),
          ]
        )
        #expect(try await unsyncedRecordNames() == [])

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
          try #expect(Reminder.all.fetchCount(db) == 0)
        }
        #expect(serverRecordNames() == [])
        #expect(try await deletedRecordNames() == [])
        #expect(try await metadataCount() == 0)
        #expect(try await unsyncedRecordNames() == [])
      }

      // * Local client creates a record with a child, and both are sent.
      // * Local client deletes the record, which deletes the child too.
      // * Another device adds a grandchild under the child. This device hasn't fetched it.
      // * The engine restarts without the deletions in its queue.
      // => Both deletions are sent, and the grandchild goes with them.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func lostDeletionOfTreeWithGrandchildAddedElsewhereDeletesTheGrandchild() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            ModelA.Draft(id: 1)
            ModelB(id: 1, modelAID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.userWrite { db in
          try ModelA.find(1).delete().execute(db)
        }
        let modelCRecord = CKRecord(
          recordType: ModelC.tableName,
          recordID: ModelC.recordID(for: 1)
        )
        modelCRecord.setValue(1, forKey: "id", at: 30)
        modelCRecord.setValue("Note", forKey: "title", at: 30)
        modelCRecord.setValue(1, forKey: "modelBID", at: 30)
        modelCRecord.parent = CKRecord.Reference(recordID: ModelB.recordID(for: 1), action: .none)
        try saveOnServer([modelCRecord])

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(
          Set(syncEngine.private.state.pendingRecordZoneChanges) == [
            .deleteRecord(ModelA.recordID(for: 1)),
            .deleteRecord(ModelB.recordID(for: 1)),
            .deleteRecord(ModelC.recordID(for: 1)),
          ]
        )

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(ModelA.all.fetchCount(db) == 0)
          try #expect(ModelB.all.fetchCount(db) == 0)
          try #expect(ModelC.all.fetchCount(db) == 0)
        }
        #expect(serverRecordNames() == [])
        #expect(try await deletedRecordNames() == [])
        #expect(try await unsyncedRecordNames() == [])
      }

      // * Local client creates a record with two children and a grandchild under the first one,
      //   and all of them are sent.
      // * Local client deletes the record, which deletes everything under it.
      // * Another device edits the grandchild. This device hasn't fetched the edit.
      // * The engine restarts without the deletions in its queue.
      // => Every deletion is sent: the edit below the record doesn't bring any of it back.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func lostDeletionOfTreeEditedBelowItsRootIsSentWhole() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            ModelA.Draft(id: 1)
            ModelB(id: 1, modelAID: 1)
            ModelB(id: 2, modelAID: 1)
            ModelC(id: 1, title: "Note", modelBID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.userWrite { db in
          try ModelA.find(1).delete().execute(db)
        }
        let record = try container.privateCloudDatabase.record(for: ModelC.recordID(for: 1))
        record.setValue("Edited", forKey: "title", at: 30)
        try saveOnServer([record])

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(
          Set(syncEngine.private.state.pendingRecordZoneChanges) == [
            .deleteRecord(ModelA.recordID(for: 1)),
            .deleteRecord(ModelB.recordID(for: 1)),
            .deleteRecord(ModelB.recordID(for: 2)),
            .deleteRecord(ModelC.recordID(for: 1)),
          ]
        )

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(ModelA.all.fetchCount(db) == 0)
          try #expect(ModelB.all.fetchCount(db) == 0)
          try #expect(ModelC.all.fetchCount(db) == 0)
        }
        #expect(serverRecordNames() == [])
        #expect(try await deletedRecordNames() == [])
      }

      // * Local client creates a list, and it is sent.
      // * Local client deletes the list, and another device deletes it too.
      // * The engine restarts without the deletion in its queue.
      // => Nothing is sent, since the record is already gone, and nothing is left behind.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func lostDeletionOfRecordDeletedElsewhereLeavesNothingBehind() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
        }
        try deleteOnServer([RemindersList.recordID(for: 1)])

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)

        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
        }
        #expect(try await metadataCount() == 0)
      }

      // * Local client creates a list, and it is sent.
      // * Local client deletes the list.
      // * The engine restarts without the deletion in its queue, and can't reach iCloud to check
      //   the list.
      // * The engine restarts again, and iCloud can be reached.
      // => The deletion is not sent unchecked: it waits, flagged, until the next start can check
      //    the list, and is sent then.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func lostDeletionWaitsUntilICloudCanBeChecked() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.userWrite { db in
          try RemindersList.find(1).delete().execute(db)
        }
        container.privateCloudDatabase.state.withValue {
          $0.recordsLookupError = CKError(.networkUnavailable)
        }

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        #expect(try await deletedRecordNames() == [RemindersList.recordName(for: 1)])

        container.privateCloudDatabase.state.withValue { $0.recordsLookupError = nil }

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(
          syncEngine.private.state.pendingRecordZoneChanges == [
            .deleteRecord(RemindersList.recordID(for: 1))
          ]
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(serverRecordNames() == [])
        #expect(try await deletedRecordNames() == [])
      }

      // * Another user shares a list with a reminder with this user.
      // * Local client deletes the reminder.
      // * The other user renames the reminder. This device hasn't fetched the rename.
      // * The engine restarts without the deletion in its queue.
      // => The deletion is sent to the shared database all the same, and the list stays.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func lostDeletionInSharedZoneOfRecordEditedElsewhereIsSent() async throws {
        let externalZone = CKRecordZone(
          zoneID: CKRecordZone.ID(
            zoneName: "external.zone",
            ownerName: "external.owner"
          )
        )
        try await syncEngine.modifyRecordZones(scope: .shared, saving: [externalZone]).notify()

        let remindersListRecord = CKRecord(
          recordType: RemindersList.tableName,
          recordID: RemindersList.recordID(for: 1, zoneID: externalZone.zoneID)
        )
        remindersListRecord.setValue(1, forKey: "id", at: now)
        remindersListRecord.setValue("Personal", forKey: "title", at: now)
        let reminderRecord = CKRecord(
          recordType: Reminder.tableName,
          recordID: Reminder.recordID(for: 1, zoneID: externalZone.zoneID)
        )
        reminderRecord.setValue(1, forKey: "id", at: now)
        reminderRecord.setValue(false, forKey: "isCompleted", at: now)
        reminderRecord.setValue("Get milk", forKey: "title", at: now)
        reminderRecord.setValue(1, forKey: "remindersListID", at: now)
        reminderRecord.parent = CKRecord.Reference(record: remindersListRecord, action: .none)
        let share = CKShare(
          rootRecord: remindersListRecord,
          shareID: CKRecord.ID(
            recordName: "share-\(remindersListRecord.recordID.recordName)",
            zoneID: remindersListRecord.recordID.zoneID
          )
        )
        share.publicPermission = .readWrite
        try await syncEngine.modifyRecords(
          scope: .shared,
          saving: [remindersListRecord, reminderRecord, share]
        ).notify()

        try await withDependencies {
          $0.currentTime.now += 60
        } operation: {
          try await userDatabase.userWrite { db in
            try Reminder.find(1).delete().execute(db)
          }
        }
        let editedReminder = try container.sharedCloudDatabase.record(
          for: Reminder.recordID(for: 1, zoneID: externalZone.zoneID)
        )
        editedReminder.setValue("Buy milk", forKey: "title", at: 90)
        try saveOnServer([editedReminder], .shared)

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(
          syncEngine.shared.state.pendingRecordZoneChanges == [
            .deleteRecord(Reminder.recordID(for: 1, zoneID: externalZone.zoneID))
          ]
        )

        try await syncEngine.processPendingRecordZoneChanges(scope: .shared)
        try await syncEngine.shared.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(Reminder.all.fetchCount(db) == 0)
          try #expect(RemindersList.all.fetchCount(db) == 1)
        }
        #expect(!serverRecordNames(.shared).contains(Reminder.recordName(for: 1)))
        #expect(serverRecordNames(.shared).contains(RemindersList.recordName(for: 1)))
        #expect(try await deletedRecordNames() == [])
      }

      /// The number of rows in the metadata table.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func metadataCount() async throws -> Int {
        try await syncEngine.metadatabase.read { db in
          try SyncMetadata.count().fetchOne(db) ?? 0
        }
      }

      /// The record names waiting on this device for a parent that hasn't arrived.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func unsyncedRecordNames() async throws -> Set<String> {
        try await syncEngine.metadatabase.read { db in
          Set(try UnsyncedRecordID.all.fetchAll(db).map(\.recordName))
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
