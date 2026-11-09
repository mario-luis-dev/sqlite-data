#if canImport(CloudKit)
  import CloudKit
  import SQLiteData
  import Testing

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension BaseCloudKitTests {
    /// The record names whose metadata is flagged `_isDeleted`: local deletions that CloudKit
    /// hasn't confirmed.
    func flaggedRecordNames() async throws -> Set<String> {
      try await syncEngine.metadatabase.read { db in
        Set(try SyncMetadata.where(\._isDeleted).select(\.recordName).fetchAll(db))
      }
    }

    /// The record names that have metadata, flagged or not.
    func metadataRecordNames() async throws -> Set<String> {
      try await syncEngine.metadatabase.read { db in
        Set(try SyncMetadata.select(\.recordName).fetchAll(db))
      }
    }

    /// Flags the metadata of rows that are on the device, as older versions of the library left
    /// them, without queueing anything.
    ///
    /// Before deletions kept their metadata until CloudKit confirmed them, a fetch wrote a deleted
    /// row back when its deletion hadn't been sent yet, and left the flag on. When the deletion
    /// then dropped out of CKSyncEngine's queue (its saved state was reset or lost), the row stayed
    /// on the device, flagged, with nothing queued. The current code can't reach that state, so it
    /// is written the way the sync engine wrote it, as the sync engine, so that no trigger runs.
    func flagAsLeftByOlderVersion(_ recordIDs: [CKRecord.ID]) async throws {
      try await userDatabase.write { db in
        try SyncMetadata
          .findAll(recordIDs)
          .update { $0._isDeleted = true }
          .execute(db)
      }
    }

    func cloudDatabase(_ scope: CKDatabase.Scope) -> MockCloudDatabase {
      scope == .shared ? container.sharedCloudDatabase : container.privateCloudDatabase
    }

    /// The record names stored on the server, in every zone of the database.
    func serverRecordNames(_ scope: CKDatabase.Scope = .private) -> Set<String> {
      cloudDatabase(scope).state.withValue { state in
        Set(state.storage.values.flatMap { $0.records.keys.map(\.recordName) })
      }
    }

    /// Every record name the server has deleted, including deletions a fetch already delivered.
    func serverDeletions(_ scope: CKDatabase.Scope = .private) -> [String] {
      cloudDatabase(scope).state.withValue { $0.deletionLog.map(\.recordName) }
    }

    /// Saves records on the server as another device does, without this device fetching them.
    func saveOnServer(_ records: [CKRecord], _ scope: CKDatabase.Scope = .private) throws {
      let (saveResults, _) = try cloudDatabase(scope).modifyRecords(saving: records)
      for (recordID, result) in saveResults {
        if case .failure(let error) = result {
          Issue.record("Saving \(recordID.recordName) on the server failed: \(error)")
        }
      }
    }

    /// Deletes records on the server as another device does, without this device fetching that.
    func deleteOnServer(_ recordIDs: [CKRecord.ID], _ scope: CKDatabase.Scope = .private) throws {
      let (_, deleteResults) = try cloudDatabase(scope).modifyRecords(deleting: recordIDs)
      for (recordID, result) in deleteResults {
        if case .failure(let error) = result {
          Issue.record("Deleting \(recordID.recordName) on the server failed: \(error)")
        }
      }
    }

    /// The record the server holds, or `nil` when it doesn't have one.
    func serverRecord(_ recordID: CKRecord.ID, _ scope: CKDatabase.Scope = .private) -> CKRecord? {
      cloudDatabase(scope).state.withValue { state in
        state.storage[recordID.zoneID]?.records[recordID]
      }
    }
  }
#endif
