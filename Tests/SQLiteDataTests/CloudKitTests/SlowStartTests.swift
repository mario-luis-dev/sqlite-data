#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtras
  import Dependencies
  import Foundation
  import SQLiteData
  import SQLiteDataTestSupport
  import TestLocals
  import Testing

  #if canImport(UIKit)
    import UIKit
  #endif

  extension BaseCloudKitTests {
    /// Starting the sync engine while `CKSyncEngine` decodes a large saved state.
    ///
    /// `CKSyncEngine` decodes the state saved by the previous launch when it is created, and the
    /// state holds every change still waiting to be sent: 15 MB took 13 to 14 seconds on a device.
    /// Nothing else may wait for that. Checking whether sync is running, saving a change, stopping
    /// sync, and the app leaving the foreground all have to go on as usual, often on the main
    /// thread, where waiting freezes the app and, at launch, gets it killed by the system.
    ///
    /// The tests hold back the creation of the sync engines with an ``EngineBuildGate``.
    ///
    /// NB: Not `@MainActor`: a test that waits on the main actor could not notice the main actor
    ///     being blocked, nor open the gate that unblocks it. Serialized: each test holds threads
    ///     of the shared concurrency pool while the gate is closed, and tests running side by side
    ///     could take every thread, including the ones the tests need to open their gates.
    @Suite(.serialized, .timeLimit(.minutes(1)), .taskLocal($startImmediately, false))
    final class SlowStartTests: BaseCloudKitTests, @unchecked Sendable {
      // * The engine starts, and its saved state takes long to decode.
      // * Meanwhile, something checks whether sync is running.
      // => It gets its answer right away: sync isn't running yet.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func syncStatusAnswersWhileSavedStateIsRead() async throws {
        engineBuildGate.close()
        let start = Task { [syncEngine] in try await syncEngine.start() }
        #expect(await engineBuildGate.waitForBuilds(1))

        let wasRunning = LockIsolated<Bool?>(nil)
        let probe = Probe { [syncEngine] in wasRunning.setValue(syncEngine.isRunning) }
        #expect(
          await probe.finishes(),
          "Checking whether sync is running waited for the saved state to be read"
        )

        engineBuildGate.open()
        try await start.value
        try await probe.task.value
        #expect(wasRunning.value == false)
        #expect(syncEngine.isRunning)
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
      }

      // * Sync is running, with a queue so large that CKSyncEngine takes long over it (it saves the
      //   whole queue each time it changes: about 400 ms for 40 MB in the simulator).
      // * A list is created, and its trigger queues it with the engine, which takes long.
      // * Meanwhile, something checks whether sync is running.
      // => It gets its answer right away: the engine's queue is never changed under the lock that
      //    checking whether sync is running takes.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func syncStatusAnswersWhileTheQueueIsBusy() async throws {
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
        // NB: The gate holds back adding to the queue here, instead of creating the engines.
        let queueBusy = EngineBuildGate()
        queueBusy.close()
        syncEngine.private.state.beforeAddingRecordZoneChanges.setValue { queueBusy.pass() }

        let creation = Task { [userDatabase] in
          try await userDatabase.userWrite { db in
            try db.seed {
              RemindersList(id: 1, title: "Personal")
            }
          }
        }
        #expect(await queueBusy.waitForBuilds(1))
        let probe = Probe { [syncEngine] in _ = syncEngine.isRunning }
        #expect(
          await probe.finishes(),
          "Checking whether sync is running waited for the engine's queue"
        )

        queueBusy.open()
        try await creation.value
        try await probe.task.value
        syncEngine.private.state.beforeAddingRecordZoneChanges.setValue(nil)
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        #expect(serverRecordNames() == [RemindersList.recordID(for: 1).recordName])
      }

      // * Local client creates a list, and it is sent. Sync stops.
      // * The engine starts again, and its saved state takes long to decode.
      // * Meanwhile, the list is renamed.
      // => The rename is saved right away, and it is sent once sync is running.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func changeSavedWhileSavedStateIsReadDoesNotWaitAndIsSent() async throws {
        try await startWithSentList()

        engineBuildGate.close()
        let start = Task { [syncEngine] in try await syncEngine.start() }
        #expect(await engineBuildGate.waitForBuilds(2))

        let rename = Probe { [userDatabase] in
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).update { $0.title = "Business" }.execute(db)
          }
        }
        #expect(await rename.finishes(), "Saving a change waited for the saved state to be read")

        engineBuildGate.open()
        try await start.value
        try await rename.task.value
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(
          serverRecord(RemindersList.recordID(for: 1))?.encryptedValues["title"] as? String
            == "Business"
        )
      }

      // * Local client creates a list, and it is sent. Sync stops.
      // * The engine starts again, and its saved state takes long to decode.
      // * Meanwhile, the list is deleted.
      // => The deletion is saved right away, and it is sent once sync is running.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func deletionWhileSavedStateIsReadDoesNotWaitAndIsSent() async throws {
        try await startWithSentList()

        engineBuildGate.close()
        let start = Task { [syncEngine] in try await syncEngine.start() }
        #expect(await engineBuildGate.waitForBuilds(2))

        let deletion = Probe { [userDatabase] in
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).delete().execute(db)
          }
        }
        #expect(
          await deletion.finishes(),
          "Deleting a row waited for the saved state to be read"
        )

        engineBuildGate.open()
        try await start.value
        try await deletion.task.value
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(serverRecordNames() == [])
        #expect(serverDeletions() == [RemindersList.recordID(for: 1).recordName])
        #expect(try await metadataRecordNames() == [])
      }

      // * Local client creates a list, and it is sent. Sync stops.
      // * The engine starts again, and its saved state takes long to decode.
      // * Meanwhile, the list is renamed while the database is busy with other work: the rename is
      //   saved before sync runs, but its note for the start can only be written once sync is
      //   running, and once the start began looking for such notes.
      // => The rename is sent all the same, without waiting for the next launch. (Two things see
      //    to it: the start reads the notes in a write, which waits for the note, and the note's
      //    write queues the change itself once sync is running. Either one alone suffices.)
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func changeSavedAsSyncStartsIsNotLost() async throws {
        try await startWithSentList()

        engineBuildGate.close()
        let start = Task { [syncEngine] in try await syncEngine.start() }
        #expect(await engineBuildGate.waitForBuilds(2))

        let renamed = LockIsolated(false)
        let releaseDatabase = DispatchSemaphore(value: 0)
        let rename = Probe { [userDatabase] in
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).update { $0.title = "Business" }.execute(db)
            renamed.setValue(true)
            // NB: Keeps the database busy, as other work at launch can.
            releaseDatabase.wait()
          }
        }
        let renameSaved = Probe {
          while !renamed.value { try await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(
          await renameSaved.finishes(),
          "Saving a change waited for the saved state to be read"
        )

        engineBuildGate.open()
        let syncRunning = Probe { [syncEngine] in
          while !syncEngine.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(await syncRunning.finishes(within: .seconds(5)))
        // NB: Gives the start time to look for the changes saved while sync wasn't running.
        try await Task.sleep(for: .milliseconds(300))
        releaseDatabase.signal()
        try await rename.task.value
        try await start.value
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        #expect(
          serverRecord(RemindersList.recordID(for: 1))?.encryptedValues["title"] as? String
            == "Business"
        )
      }

      // * Local client creates a list, and it is sent. Sync stops.
      // * The engine starts again, and its saved state takes long to decode.
      // * Meanwhile, the list is renamed while the database is busy with other work.
      // * Sync is running, and stops before the start is done with its work, and before the note
      //   of the rename is written.
      // => The rename waits for the next start, which sends it: the start that the stop cut short
      //    doesn't throw its note away.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func changeSavedAsSyncStopsDuringStartIsSentByTheNextStart() async throws {
        try await startWithSentList()

        engineBuildGate.close()
        let start = Task { [syncEngine] in try await syncEngine.start() }
        #expect(await engineBuildGate.waitForBuilds(2))

        let renamed = LockIsolated(false)
        let releaseDatabase = DispatchSemaphore(value: 0)
        let rename = Probe { [userDatabase] in
          try await userDatabase.userWrite { db in
            try RemindersList.find(1).update { $0.title = "Business" }.execute(db)
            renamed.setValue(true)
            // NB: Keeps the database busy, as other work at launch can.
            releaseDatabase.wait()
          }
        }
        let renameSaved = Probe {
          while !renamed.value { try await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(await renameSaved.finishes())

        engineBuildGate.open()
        let syncRunning = Probe { [syncEngine] in
          while !syncEngine.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(await syncRunning.finishes(within: .seconds(5)))
        syncEngine.stop()
        releaseDatabase.signal()
        try await rename.task.value
        try await start.value
        #expect(!syncEngine.isRunning)

        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        #expect(
          serverRecord(RemindersList.recordID(for: 1))?.encryptedValues["title"] as? String
            == "Business"
        )
      }

      // * The engine starts. CloudKit reports the account as soon as the private sync engine is
      //   created, while the shared one is still being created.
      // => The report is handled once the engines are in place: it isn't dropped for coming from an
      //    engine that wasn't in place yet.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test(.taskLocal($syncEngineDelegate, AccountChangedDelegate()))
      func accountReportedWhileEnginesAreCreatedIsHandled() async throws {
        engineBuildGate.closeAfterPrivateEngine()
        let start = Task { [syncEngine] in try await syncEngine.start() }
        let privateSyncEngine = try #require(await engineBuildGate.waitForPrivateEngine())

        let accountReport = Probe { [syncEngine] in
          await syncEngine.handleEvent(
            .accountChange(changeType: .signIn(currentUser: CKRecord.ID(recordName: "currentUser"))),
            syncEngine: privateSyncEngine
          )
        }
        try await Task.sleep(for: .milliseconds(200))

        engineBuildGate.open()
        try await start.value
        try await accountReport.task.value
        let delegate = try #require(syncEngineDelegate as? AccountChangedDelegate)
        #expect(delegate.wasCalled.value, "The account report was dropped")
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
      }

      // * Local client shares a list. Sync stops.
      // * The engine starts again, and its saved state takes long to decode.
      // * Meanwhile, the list stops being shared.
      // => Unsharing waits for sync to start, then deletes the share from iCloud: it doesn't return
      //    having done nothing.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func unshareWhileSavedStateIsReadWaitsAndDeletesTheShare() async throws {
        let remindersList = RemindersList(id: 1, title: "Personal")
        try await userDatabase.userWrite { db in
          try db.seed {
            remindersList
          }
        }
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        _ = try await syncEngine.share(record: remindersList, configure: { _ in })
        let shareRecordName = "share-\(RemindersList.recordID(for: 1).recordName)"
        #expect(serverRecordNames().contains(shareRecordName))
        syncEngine.stop()

        engineBuildGate.close()
        let start = Task { [syncEngine] in try await syncEngine.start() }
        #expect(await engineBuildGate.waitForBuilds(2))

        let unshare = Probe { [syncEngine] in try await syncEngine.unshare(record: remindersList) }
        try await Task.sleep(for: .milliseconds(200))

        engineBuildGate.open()
        try await start.value
        try await unshare.task.value
        #expect(!serverRecordNames().contains(shareRecordName))
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
      }

      // * Sync starts. Another user shares a list, in a zone of their own. Sync stops.
      // * The engine starts again, and its saved state takes long to decode.
      // * Meanwhile, the share is accepted.
      // => Accepting waits for sync to start, then fetches the shared list.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func acceptShareWhileSavedStateIsReadWaitsAndFetchesTheSharedRecords() async throws {
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
        let externalZone = CKRecordZone(
          zoneID: CKRecordZone.ID(zoneName: "external.zone", ownerName: "external.owner")
        )
        try await syncEngine.modifyRecordZones(scope: .shared, saving: [externalZone]).notify()
        syncEngine.stop()
        let remindersListRecord = CKRecord(
          recordType: RemindersList.tableName,
          recordID: RemindersList.recordID(for: 1, zoneID: externalZone.zoneID)
        )
        remindersListRecord.setValue(1, forKey: "id", at: now)
        remindersListRecord.setValue("Personal", forKey: "title", at: now)
        let share = CKShare(
          rootRecord: remindersListRecord,
          shareID: CKRecord.ID(
            recordName: "share-\(remindersListRecord.recordID.recordName)",
            zoneID: remindersListRecord.recordID.zoneID
          )
        )

        engineBuildGate.close()
        let start = Task { [syncEngine] in try await syncEngine.start() }
        #expect(await engineBuildGate.waitForBuilds(2))

        let acceptShare = Probe { [syncEngine, container] in
          try await syncEngine.acceptShare(
            metadata: ShareMetadata(
              containerIdentifier: container.containerIdentifier!,
              hierarchicalRootRecordID: remindersListRecord.recordID,
              rootRecord: remindersListRecord,
              share: share
            )
          )
        }
        try await Task.sleep(for: .milliseconds(200))

        engineBuildGate.open()
        try await start.value
        try await acceptShare.task.value
        let lists = try await userDatabase.read { db in try RemindersList.all.fetchAll(db) }
        #expect(lists == [RemindersList(id: 1, title: "Personal")])
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
      }

      // * The engine starts, and its saved state takes long to decode.
      // * Meanwhile, the engine is started again.
      // => The second start returns once sync is running, and only one set of sync engines is
      //    ever created: CloudKit expects one sync engine per database.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func secondStartWaitsForTheFirstAndCreatesNoOtherEngines() async throws {
        engineBuildGate.close()
        let first = Task { [syncEngine] in try await syncEngine.start() }
        #expect(await engineBuildGate.waitForBuilds(1))

        let wasRunningAfterSecondStart = LockIsolated<Bool?>(nil)
        let second = Probe { [syncEngine] in
          try await syncEngine.start()
          wasRunningAfterSecondStart.setValue(syncEngine.isRunning)
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(engineBuildGate.buildCount == 1)
        #expect(wasRunningAfterSecondStart.value == nil)

        engineBuildGate.open()
        try await first.value
        try await second.task.value
        #expect(wasRunningAfterSecondStart.value == true)
        #expect(engineBuildGate.buildCount == 1)
        #expect(engineBuildGate.mostBuildsAtOnce == 1)
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
      }

      // * Sync starts, and stops.
      // * The engine starts again, and its saved state takes long to decode.
      // * Meanwhile, sync is stopped.
      // => Stopping returns right away, and sync stays stopped once the state is decoded. A list
      //    created now is sent by the next start.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func stopWhileSavedStateIsReadDoesNotWaitAndSyncStaysStopped() async throws {
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
        syncEngine.stop()

        engineBuildGate.close()
        let start = Task { [syncEngine] in try await syncEngine.start() }
        #expect(await engineBuildGate.waitForBuilds(2))

        let stop = Probe { [syncEngine] in syncEngine.stop() }
        #expect(await stop.finishes(), "Stopping sync waited for the saved state to be read")

        engineBuildGate.open()
        try await start.value
        try await stop.task.value
        #expect(!syncEngine.isRunning)

        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.start()
        #expect(engineBuildGate.buildCount == 3)
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        #expect(serverRecordNames() == [RemindersList.recordID(for: 1).recordName])
      }

      // * The engine starts, and its saved state takes long to decode.
      // * Meanwhile, sync is stopped and started again.
      // => The new start waits until the first set of sync engines is created and thrown away,
      //    so two sets never exist at once, and sync ends up running.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func stopAndStartAgainWhileSavedStateIsReadNeverRunsTwoSetsOfEngines() async throws {
        engineBuildGate.close()
        let first = Task { [syncEngine] in try await syncEngine.start() }
        #expect(await engineBuildGate.waitForBuilds(1))

        let stop = Probe { [syncEngine] in syncEngine.stop() }
        #expect(await stop.finishes(), "Stopping sync waited for the saved state to be read")
        let second = Task { [syncEngine] in try await syncEngine.start() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(
          engineBuildGate.buildCount == 1,
          "A second set of sync engines was created while the first was being created"
        )

        engineBuildGate.open()
        try await first.value
        try await second.value
        try await stop.task.value
        #expect(syncEngine.isRunning)
        #expect(engineBuildGate.buildCount == 2)
        #expect(engineBuildGate.mostBuildsAtOnce == 1)
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
      }

      // * Sync starts, and stops.
      // * Another device creates a list.
      // * The engine starts again, and its saved state takes long to decode.
      // * Meanwhile, the app asks for a fetch.
      // => The fetch waits for sync to start, then fetches: it doesn't return having done nothing.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func fetchRequestedWhileSavedStateIsReadWaitsAndFetches() async throws {
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
        syncEngine.stop()
        let record = CKRecord(
          recordType: RemindersList.tableName,
          recordID: RemindersList.recordID(for: 1)
        )
        record.setValue(1, forKey: "id", at: now)
        record.setValue("Personal", forKey: "title", at: now)
        try saveOnServer([record])

        engineBuildGate.close()
        let start = Task { [syncEngine] in try await syncEngine.start() }
        #expect(await engineBuildGate.waitForBuilds(2))

        let fetch = Probe { [syncEngine] in try await syncEngine.fetchChanges() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!(await fetch.finishes(within: .zero)), "The fetch returned before sync started")

        engineBuildGate.open()
        try await start.value
        try await fetch.task.value
        let lists = try await userDatabase.read { db in try RemindersList.all.fetchAll(db) }
        #expect(lists == [RemindersList(id: 1, title: "Personal")])
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
      }

      // * Sync starts, and stops. A list is created while sync is stopped.
      // * The engine starts again, and its saved state takes long to decode.
      // * Meanwhile, the app asks for its changes to be sent.
      // => Sending waits for sync to start, then sends the list: it doesn't return having sent
      //    nothing.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func sendRequestedWhileSavedStateIsReadWaitsAndSends() async throws {
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
        syncEngine.stop()
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }

        engineBuildGate.close()
        let start = Task { [syncEngine] in try await syncEngine.start() }
        #expect(await engineBuildGate.waitForBuilds(2))

        let send = Probe { [syncEngine] in try await syncEngine.sendChanges() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!(await send.finishes(within: .zero)), "Sending returned before sync started")

        engineBuildGate.open()
        try await start.value
        try await send.task.value
        #expect(serverRecordNames() == [RemindersList.recordID(for: 1).recordName])
      }

      // * The app starts sync from the main actor.
      // => The saved state is decoded off the main thread.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @MainActor
      @Test func startFromMainActorReadsSavedStateOffTheMainThread() async throws {
        try await syncEngine.start()
        #expect(engineBuildGate.buildsOnMain == 0)
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
      }

      #if canImport(UIKit)
        @Dependency(\.defaultNotificationCenter) var defaultNotificationCenter

        // * The engine starts, and its saved state takes long to decode.
        // * Meanwhile, the app leaves the foreground (the app switcher, Control Center, a call).
        // => The main thread stays free.
        @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
        @Test func leavingTheAppWhileSavedStateIsReadKeepsTheMainThreadFree() async throws {
          engineBuildGate.close()
          let start = Task { [syncEngine] in try await syncEngine.start() }
          #expect(await engineBuildGate.waitForBuilds(1))

          defaultNotificationCenter.post(
            name: UIApplication.willResignActiveNotification,
            object: nil
          )
          try await Task.sleep(for: .milliseconds(100))
          let mainThread = Probe { await MainActor.run {} }
          #expect(
            await mainThread.finishes(),
            "Leaving the app blocked the main thread while the saved state was read"
          )

          engineBuildGate.open()
          try await start.value
          try await mainThread.task.value
          try await Task.sleep(for: .seconds(1))
          try await syncEngine.processPendingDatabaseChanges(scope: .private)
        }
      #endif

      /// Starts sync with a list that is sent, and stops it, as the launch before this one ended.
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func startWithSentList() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.start()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        syncEngine.stop()
      }
    }
  }
#endif
