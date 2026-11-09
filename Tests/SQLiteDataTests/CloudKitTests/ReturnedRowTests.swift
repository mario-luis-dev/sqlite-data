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
    /// Such a row must never be deleted on the server. CloudKit deletes a parent record even when
    /// other records still point at it (`CKRecord.ReferenceAction.none`), and every other device
    /// then deletes the row and everything under it, while their own copies of the children
    /// never come back. Its flag must go too, or fetches keep skipping other devices' edits of it.
    @MainActor
    final class ReturnedRowTests: BaseCloudKitTests, @unchecked Sendable {
      // * Local client creates a list with a reminder, and both are sent.
      // * An older version left both rows flagged as deleted while they are on the device.
      // * The engine starts.
      // => Neither is deleted, and nothing is sent: both rows match the server. The flags go.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func returnedRowsStayAndAreNotSentAgain() async throws {
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

        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        #expect(try await flaggedRecordNames() == [])
        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchAll(db) == [RemindersList(id: 1, title: "Personal")])
          try #expect(Reminder.all.fetchCount(db) == 1)
        }
        #expect(
          serverRecordNames() == [RemindersList.recordName(for: 1), Reminder.recordName(for: 1)]
        )
        #expect(serverDeletions() == [])
      }

      // * Local client creates a list, and it is sent.
      // * An older version left the list flagged as deleted while it is on the device.
      // * Local client adds a reminder to the list, and it is sent.
      // * The engine starts.
      // => The list is not deleted. Real CloudKit would delete it while the reminder points at it,
      //    and every other device would then delete the list and the reminder. The fake server
      //    refuses that deletion instead, so the queue is what shows it.
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
        #expect(
          serverRecordNames() == [RemindersList.recordName(for: 1), Reminder.recordName(for: 1)]
        )
        #expect(serverDeletions() == [])
      }

      // * Local client creates a list, and it is sent.
      // * An older version left the list flagged as deleted while it is on the device.
      // * The engine starts, and then another device renames the list.
      // => The rename reaches this device.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func returnedRowReceivesOtherDevicesEdits() async throws {
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
          try #expect(RemindersList.all.fetchAll(db) == [RemindersList(id: 1, title: "Business")])
        }
        #expect(try await flaggedRecordNames() == [])
      }

      // * Local client creates a list, and it is sent.
      // * An older version left the list flagged as deleted while it is on the device.
      // * Another device renames the list, and this device fetches the rename before the engine
      //   restarts, which skips it because the row is flagged.
      // * The engine starts. Its change token is past the rename, so no later fetch delivers it.
      // => The rename reaches this device all the same, and nothing is deleted or sent.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func returnedRowGetsEditFetchedBeforeStart() async throws {
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
          try #expect(RemindersList.all.fetchAll(db) == [RemindersList(id: 1, title: "Business")])
        }
        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        #expect(try await flaggedRecordNames() == [])
        #expect(serverDeletions() == [])
      }

      // * Local client creates a list, and it is sent.
      // * An older version left the list flagged as deleted while it is on the device.
      // * Another device deletes the list. This device hasn't fetched that yet.
      // * The engine starts, and then fetches the deletion.
      // => The list is deleted on this device too, and nothing brings it back to the server: an
      //    upload sent before the fetch would recreate a record another device deleted.
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

        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)

        try await syncEngine.private.fetchChanges(CKSyncEngine.FetchChangesOptions())

        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 0)
        }
        #expect(serverRecordNames() == [])
        #expect(try await metadataRecordNames() == [])
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
      // => The deletion is not sent, and leaves the queue.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func queuedDeletionOfReturnedRowIsNeverSent() async throws {
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

        #expect(serverRecordNames() == [RemindersList.recordName(for: 1)])
        #expect(serverDeletions() == [])
        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        try await userDatabase.read { db in
          try #expect(RemindersList.all.fetchCount(db) == 1)
        }
      }

      // * Local client shares a list with a reminder, and all of it is sent.
      // * An older version left the list and the reminder flagged as deleted while they are on
      //   the device, and their deletions, with the share's, are still in CKSyncEngine's queue.
      // * The engine starts and sends.
      // => Nothing is deleted: the list stays shared, with its reminder.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func returnedSharedRootKeepsItsShare() async throws {
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

        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)

        let shareRecordID = CKRecord.ID(
          recordName: "share-\(RemindersList.recordID(for: 1).recordName)",
          zoneID: syncEngine.defaultZone.zoneID
        )
        // NB: The fakes start every engine from an empty state. This puts back the deletions a
        //     saved state that kept them would hold.
        syncEngine.private.state.add(
          pendingRecordZoneChanges: [
            .deleteRecord(RemindersList.recordID(for: 1)),
            .deleteRecord(shareRecordID),
            .deleteRecord(Reminder.recordID(for: 1)),
          ]
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(
          serverRecordNames() == [
            RemindersList.recordName(for: 1),
            Reminder.recordName(for: 1),
            shareRecordID.recordName,
          ]
        )
        #expect(serverDeletions() == [])
        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        #expect(try await flaggedRecordNames() == [])
      }

      // * Local client creates a list, and it is sent.
      // * An older version left the list flagged as deleted while it is on the device.
      // * The engine starts, and local client renames the list.
      // * The engine restarts.
      // => The rename is sent, and the restart queues nothing: the list is not deleted later.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func returnedRowEditedLocallyIsUploadedAndNeverDeletedLater() async throws {
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

        try await userDatabase.userWrite { db in
          try RemindersList.find(1).update { $0.title = "Groceries" }.execute(db)
        }
        #expect(
          syncEngine.private.state.pendingRecordZoneChanges == [
            .saveRecord(RemindersList.recordID(for: 1))
          ]
        )
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(
          serverRecord(RemindersList.recordID(for: 1))?.encryptedValues["title"] as? String
            == "Groceries"
        )
        #expect(try await flaggedRecordNames() == [])

        syncEngine.stop()
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)

        #expect(syncEngine.private.state.pendingRecordZoneChanges.isEmpty)
        #expect(serverDeletions() == [])
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
      // => Nothing is deleted in the other user's zone. Only the second reminder is sent, to the
      //    shared database, and the first one is left as it is.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func returnedRowsInSharedZoneStay() async throws {
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
          syncEngine.shared.state.pendingRecordZoneChanges == [
            .saveRecord(Reminder.recordID(for: 2, zoneID: externalZone.zoneID))
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
            Reminder.recordName(for: 1),
            Reminder.recordName(for: 2),
            share.recordID.recordName,
          ]
        )
        #expect(serverDeletions(.shared) == [])
        #expect(try await flaggedRecordNames() == [])
      }
    }
  }
#endif
