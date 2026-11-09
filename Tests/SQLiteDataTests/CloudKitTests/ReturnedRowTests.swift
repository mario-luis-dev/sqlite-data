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
    /// Rows that are on the device while their metadata is still flagged `_isDeleted`.
    ///
    /// Older versions of the library leave such rows behind. Before deletions kept their metadata
    /// until CloudKit confirmed them, a fetch wrote a deleted row back when its deletion had not
    /// been sent yet, and left the flag on. When the deletion then dropped out of CKSyncEngine's
    /// queue, the row stayed on the device, flagged, with nothing queued: back in the person's
    /// library, where it has been ever since. Re-creating a row with the same primary key before
    /// its deletion was sent left the same state.
    ///
    /// The person deleted such a row, so the next start deletes it again, with everything under
    /// it, on the device and on the server. A row someone took back after it returned stays
    /// instead: one holding a change the server never received, or with a row under it that the
    /// deletion didn't take. Its flag goes, or fetches keep skipping other devices' edits of it.
    @MainActor
    final class ReturnedRowTests: BaseCloudKitTests, @unchecked Sendable {
      // * Local client creates a list with a reminder, and both are sent.
      // * An older version left both rows flagged as deleted while they are on the device.
      // * The engine starts.
      // => Both are deleted again, on this device and on the server: the person deleted them.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func returnedRowsAreDeletedAgain() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
            Reminder(id: 1, title: "Get milk", remindersListID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await flagAsLeftByOlderVersion([
          RemindersList.recordID(for: 1), Reminder.recordID(for: 1),
        ])

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
          try #expect(Reminder.all.fetchCount(db) == 0)
        }
        #expect(
          Set(syncEngine.private.state.pendingRecordZoneChanges) == [
            .deleteRecord(RemindersList.recordID(for: 1)),
            .deleteRecord(Reminder.recordID(for: 1)),
          ]
        )

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(serverRecordNames() == [])
        #expect(try await flaggedRecordNames() == [])
        #expect(try await metadataRecordNames() == [])
      }

      // * Local client creates a list, and it is sent.
      // * An older version left the list flagged as deleted while it is on the device.
      // * Local client adds a reminder to the list, and it is sent.
      // * The engine starts.
      // => The list stays, with the reminder: someone took the list back after it returned. The
      //    deletion of the list took everything under it, so a row under it that isn't flagged
      //    was added since.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func returnedParentWithNewChildIsNeverDeleted() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await flagAsLeftByOlderVersion([RemindersList.recordID(for: 1)])
        try await userDatabase.userWrite { db in
          try db.seed {
            Reminder(id: 1, title: "Get milk", remindersListID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        #expect(try await flaggedRecordNames() == [])
        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 1)
          try #expect(Reminder.all.fetchCount(db) == 1)
        }
        #expect(
          serverRecordNames() == [RemindersList.recordName(for: 1), Reminder.recordName(for: 1)]
        )
        #expect(serverDeletions() == [])
      }

      // * Local client creates a list, and it is sent.
      // * An older version left the list flagged as deleted while it is on the device.
      // * The engine starts, and then another device renames the list before this device sends.
      // => The rename doesn't bring the list back, and the deletion is sent.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func returnedRowDeletedAgainIsNotBroughtBackByOtherDevicesEdit() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await flagAsLeftByOlderVersion([RemindersList.recordID(for: 1)])

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        let record = try syncEngine.private.database.record(for: RemindersList.recordID(for: 1))
        record.setValue("Business", forKey: "title", at: 30)
        try await syncEngine.modifyRecords(scope: .private, saving: [record]).notify()

        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(serverRecordNames() == [])
        #expect(try await flaggedRecordNames() == [])
      }

      // * Local client creates a list, and it is sent.
      // * An older version left the list flagged as deleted while it is on the device.
      // * Another device renames the list, and this device fetches the rename before the engine
      //   restarts, which skips it because the row is flagged.
      // * The engine starts.
      // => The list is deleted again all the same: a deletion wins over an edit made elsewhere.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func returnedRowEditedElsewhereIsDeletedAgain() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await flagAsLeftByOlderVersion([RemindersList.recordID(for: 1)])

        let record = try syncEngine.private.database.record(for: RemindersList.recordID(for: 1))
        record.setValue("Business", forKey: "title", at: 30)
        try await syncEngine.modifyRecords(scope: .private, saving: [record]).notify()

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
        }
        #expect(
          syncEngine.private.state.pendingRecordZoneChanges == [
            .deleteRecord(RemindersList.recordID(for: 1))
          ]
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(serverRecordNames() == [])
        #expect(try await flaggedRecordNames() == [])
      }

      // * Local client creates a list, and it is sent.
      // * An older version left the list flagged as deleted while it is on the device.
      // * Another device deletes the list. This device hasn't fetched that yet.
      // * The engine starts, fetches the deletion, and sends.
      // => The list is gone on this device and on the server, and nothing is left behind.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func returnedRowDeletedElsewhereIsNotBroughtBack() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await flagAsLeftByOlderVersion([RemindersList.recordID(for: 1)])
        try deleteOnServer([RemindersList.recordID(for: 1)])

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
        }
        #expect(serverRecordNames() == [])
        #expect(try await metadataRecordNames() == [])
        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
      }

      // * Local client creates a list, and it is sent.
      // * An older version left the list flagged as deleted while it is on the device, with a
      //   title the server never received: it was deleted, created again with the same id and a
      //   new title, and the deletion dropped out of the queue.
      // * The engine starts.
      // => The new title is sent as an edit of the list, which is never deleted on the server.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func returnedRowWithUnsentChangeIsUploadedInPlace() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await userDatabase.write { db in
          try RemindersList.find(1).update { $0.title = "Business" }.execute(db)
        }
        try await flagAsLeftByOlderVersion([RemindersList.recordID(for: 1)])

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(
          syncEngine.private.state.pendingRecordZoneChanges == [
            .saveRecord(RemindersList.recordID(for: 1))
          ]
        )

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(
          serverRecord(RemindersList.recordID(for: 1))?.encryptedValues["title"] as? String
            == "Business"
        )
        #expect(serverDeletions() == [])
        #expect(try await flaggedRecordNames() == [])
      }

      // * Local client creates a list with a reminder, and both are sent.
      // * An older version left the reminder flagged as deleted while it is on the device, with a
      //   title the server never received.
      // * Another device completes the reminder, and this device fetches that before the engine
      //   restarts, which skips it because the row is flagged.
      // * The engine starts, and sends.
      // => Neither change is lost: the server and this device both end with the new title and the
      //    reminder completed.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func returnedRowWithUnsentChangeKeepsOtherDevicesEdit() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
            Reminder(id: 1, title: "Get milk", remindersListID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await userDatabase.write { db in
          try Reminder.find(1).update { $0.title = "Buy milk" }.execute(db)
        }
        try await flagAsLeftByOlderVersion([Reminder.recordID(for: 1)])

        let record = try syncEngine.private.database.record(for: Reminder.recordID(for: 1))
        record.setValue(true, forKey: "isCompleted", at: 30)
        try await syncEngine.modifyRecords(scope: .private, saving: [record]).notify()

        syncEngine.stop()
        try await withDependencies {
          $0.currentTime.now = 60
        } operation: {
          try await syncEngine.start()
        }
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        // NB: An upload built from a version the server has since replaced comes back as
        //     'serverRecordChanged', and is merged and sent again.
        if !syncEngine.private.state.pendingRecordZoneChanges.isEmpty {
          try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        }

        let serverReminder = serverRecord(Reminder.recordID(for: 1))
        #expect(serverReminder?.encryptedValues["title"] as? String == "Buy milk")
        #expect(serverReminder?.encryptedValues["isCompleted"] as? Bool == true)
        try await userDatabase.read { db in
          let reminder = try Reminder.find(1).fetchOne(db)
          #expect(reminder?.title == "Buy milk")
          #expect(reminder?.isCompleted == true)
        }
        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        #expect(serverDeletions() == [])
        #expect(try await flaggedRecordNames() == [])
      }

      // * Local client creates a list, and it is sent.
      // * An older version left the list flagged as deleted while it is on the device, and its
      //   deletion is still in CKSyncEngine's queue: the saved state kept it.
      // * The engine starts and sends.
      // => The list is deleted on this device, and the deletion is sent once.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func queuedDeletionOfReturnedRowIsSent() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await flagAsLeftByOlderVersion([RemindersList.recordID(for: 1)])

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
        // NB: The fakes start every engine from an empty state. This puts back the deletion a
        //     saved state that kept it would hold.
        syncEngine.private.state.add(
          pendingRecordZoneChanges: [.deleteRecord(RemindersList.recordID(for: 1))]
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(serverRecordNames() == [])
        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
        }
        #expect(try await metadataRecordNames() == [])
      }

      // * Local client shares a list with a reminder, and all of it is sent.
      // * An older version left the list and the reminder flagged as deleted while they are on
      //   the device, and their deletions, with the share's, are still in CKSyncEngine's queue.
      // * The engine starts and sends.
      // => The list, its reminder and its share are all deleted.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func returnedSharedRootIsDeletedWithItsShare() async throws {
        let remindersList = RemindersList(id: 1, title: "Personal")
        try await userDatabase.userWrite { db in
          try db.seed {
            remindersList
            Reminder(id: 1, remindersListID: 1)
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let _ = try await syncEngine.share(record: remindersList, configure: { _ in })
        try await flagAsLeftByOlderVersion([
          RemindersList.recordID(for: 1), Reminder.recordID(for: 1),
        ])

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        let shareRecordID = CKRecord.ID(
          recordName: "share-\(RemindersList.recordID(for: 1).recordName)",
          zoneID: syncEngine.defaultZone.zoneID
        )
        #expect(
          Set(syncEngine.private.state.pendingRecordZoneChanges) == [
            .deleteRecord(RemindersList.recordID(for: 1)),
            .deleteRecord(shareRecordID),
            .deleteRecord(Reminder.recordID(for: 1)),
          ]
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(serverRecordNames() == [])
        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        #expect(try await flaggedRecordNames() == [])
        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
          try #expect(Reminder.all.fetchCount(db) == 0)
        }
      }

      // * Local client creates a list, and it is sent.
      // * An older version left the list flagged as deleted while it is on the device.
      // * The engine starts, and sends.
      // * The engine restarts.
      // => The list is deleted once, and the restart neither queues anything nor brings it back.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func returnedRowDeletedAgainStaysDeletedAfterRestart() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        try await flagAsLeftByOlderVersion([RemindersList.recordID(for: 1)])

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(serverRecordNames() == [])
        #expect(try await metadataRecordNames() == [])

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
        }
        #expect(serverRecordNames() == [])
      }

      // * Local client creates a list. The engine stops before the list is sent, and its queue
      //   is lost.
      // * An older version left the list flagged as deleted while it is on the device.
      // * The engine starts.
      // => The list is uploaded.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func returnedRowThatNeverReachedICloudIsUploaded() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        syncEngine.stop()
        try await flagAsLeftByOlderVersion([RemindersList.recordID(for: 1)])

        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(
          syncEngine.private.state.pendingRecordZoneChanges == [
            .saveRecord(RemindersList.recordID(for: 1))
          ]
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(serverRecordNames() == [RemindersList.recordName(for: 1)])
        #expect(try await flaggedRecordNames() == [])
      }

      // * Another user shares a list with two reminders with this user.
      // * An older version left both reminders flagged as deleted while they are on the device,
      //   and the second one with a title the server never received.
      // * The engine starts.
      // => The first reminder is deleted again, in the shared database. The second one stays,
      //    since it holds a change made after it returned, which is sent to the shared database.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func returnedRowsInSharedZoneAreSettled() async throws {
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
        var reminderRecords: [CKRecord] = []
        for id in 1...2 {
          let reminderRecord = CKRecord(
            recordType: Reminder.tableName,
            recordID: Reminder.recordID(for: id, zoneID: externalZone.zoneID)
          )
          reminderRecord.setValue(id, forKey: "id", at: now)
          reminderRecord.setValue(false, forKey: "isCompleted", at: now)
          reminderRecord.setValue("Get milk", forKey: "title", at: now)
          reminderRecord.setValue(1, forKey: "remindersListID", at: now)
          reminderRecord.parent = CKRecord.Reference(record: remindersListRecord, action: .none)
          reminderRecords.append(reminderRecord)
        }
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
          saving: [remindersListRecord, share] + reminderRecords
        ).notify()

        try await userDatabase.write { db in
          try Reminder.find(2).update { $0.title = "Buy milk" }.execute(db)
        }
        try await flagAsLeftByOlderVersion([
          Reminder.recordID(for: 1, zoneID: externalZone.zoneID),
          Reminder.recordID(for: 2, zoneID: externalZone.zoneID),
        ])

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        #expect(
          Set(syncEngine.shared.state.pendingRecordZoneChanges) == [
            .deleteRecord(Reminder.recordID(for: 1, zoneID: externalZone.zoneID)),
            .saveRecord(Reminder.recordID(for: 2, zoneID: externalZone.zoneID)),
          ]
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .shared)

        #expect(
          serverRecord(Reminder.recordID(for: 2, zoneID: externalZone.zoneID), .shared)?
            .encryptedValues["title"] as? String == "Buy milk"
        )
        #expect(
          serverRecordNames(.shared) == [
            RemindersList.recordName(for: 1),
            Reminder.recordName(for: 2),
            share.recordID.recordName,
          ]
        )
        #expect(try await flaggedRecordNames() == [])
        try await userDatabase.read { db in
          try #expect(Reminder.all.fetchAll(db).map(\.id) == [2])
        }
      }
    }
  }
#endif
