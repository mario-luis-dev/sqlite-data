#if canImport(CloudKit)
  public import CloudKit
  package import ConcurrencyExtras
  import Dependencies
  public import GRDB
  public import IssueReporting
  import OrderedCollections
  public import OSLog
  import Observation
  public import StructuredQueries
  import StructuredQueriesSQLite
  #if EXCLUDE_EXPORTS
    public import StructuredQueriesSQLiteCore
  #endif
  import SwiftData
  import TabularData

  #if canImport(UIKit)
    import UIKit
  #endif

  /// An object that manages the synchronization of local and remote SQLite data.
  ///
  /// See <doc:CloudKitSync> for more information.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public final class SyncEngine: Observable, Sendable {
    package let userDatabase: UserDatabase
    package let logger: Logger
    package let metadatabase: any DatabaseWriter
    package let tables: [any SynchronizableTable]
    package let privateTables: [any SynchronizableTable]
    let tablesByName: [String: any SynchronizableTable]
    package let tablesByOrder: [String: Int]
    let foreignKeysByTableName: [String: [ForeignKey]]
    package let syncEngines = LockIsolated<SyncEngines>(SyncEngines())
    package let defaultZone: CKRecordZone
    package let delegate: (any SyncEngineDelegate)?
    let defaultSyncEngines:
      @Sendable (any DatabaseReader, SyncEngine)
        -> (private: any SyncEngineProtocol, shared: any SyncEngineProtocol)
    package let container: any CloudContainer
    let dataManager = Dependency(\.dataManager)
    let uuid = Dependency(\.uuid)
    private let observationRegistrar = ObservationRegistrar()
    private let notificationsObserver = LockIsolated<(any NSObjectProtocol)?>(nil)
    private let activityCounts = LockIsolated(ActivityCounts())
    private let startTask = LockIsolated<Task<Void, Never>?>(nil)
    private let startup = LockIsolated(Startup())
    private let quotaExceeded = LockIsolated([CKDatabase.Scope.private: false, .shared: false])
    #if DEBUG && canImport(DeveloperToolsSupport)
      private let previewTimerTask = LockIsolated<Task<Void, Never>?>(nil)
    #endif

    /// The error message used when a write occurs to a record for which the current user does not
    /// have permission.
    ///
    /// This error is thrown from any database write to a row for which the current user does
    /// not have permissions to write, as determined by its `CKShare` (if applicable). To catch
    /// this error try casting it to `DatabaseError` and checking its message:
    ///
    /// ```swift
    /// do {
    ///   try await database.write { db in
    ///     Reminder.find(id)
    ///       .update { $0.title = "Personal" }
    ///       .execute(db)
    ///   }
    /// } catch let error as DatabaseError where error.message == SyncEngine.writePermissionError {
    ///   // User does not have permission to write to this record.
    /// }
    /// ```
    public static let writePermissionError =
      "co.pointfree.SQLiteData.CloudKit.write-permission-error"
    public static let invalidRecordNameError =
      "co.pointfree.SQLiteData.CloudKit.invalid-record-name-error"

    /// Initialize a sync engine.
    ///
    /// - Parameters:
    ///   - database: The database to synchronize to CloudKit.
    ///   - tables: A list of tables that you want to synchronize _and_ that you want to be
    ///     shareable with other users on CloudKit.
    ///   - privateTables: A list of tables that you want to synchronize to CloudKit but that
    ///     you do not want to be shareable with other users.
    ///   - containerIdentifier: The container identifier in CloudKit to synchronize to. If omitted
    ///     the container will be determined from the entitlements of your app.
    ///   - defaultZone: The zone for all records to be stored in.
    ///   - startImmediately: Determines if the sync engine starts right away or requires an
    ///     explicit call to ``start()``. By default this argument is `true`.
    ///   - delegate: A delegate object that can be notified of events and override default sync
    ///     engine behavior.
    ///   - logger: The logger used to log events in the sync engine. By default a `.disabled`
    ///     logger is used, which means logs are not printed.
    public convenience init<
      each T1: PrimaryKeyedTable & _SendableMetatype,
      each T2: PrimaryKeyedTable & _SendableMetatype
    >(
      for database: any DatabaseWriter,
      tables: repeat (each T1).Type,
      privateTables: repeat (each T2).Type,
      containerIdentifier: String? = nil,
      defaultZone: CKRecordZone = CKRecordZone(zoneName: "co.pointfree.SQLiteData.defaultZone"),
      startImmediately: Bool? = nil,
      delegate: (any SyncEngineDelegate)? = nil,
      logger: Logger = isTesting
        ? Logger(.disabled) : Logger(subsystem: "SQLiteData", category: "CloudKit")
    ) throws
    where
      repeat (each T1).PrimaryKey.QueryOutput: IdentifierStringConvertible,
      repeat (each T1).TableColumns.PrimaryColumn: WritableTableColumnExpression,
      repeat (each T2).PrimaryKey.QueryOutput: IdentifierStringConvertible,
      repeat (each T2).TableColumns.PrimaryColumn: WritableTableColumnExpression
    {
      @Dependency(\.context) var context
      let containerIdentifier =
        containerIdentifier
        ?? ModelConfiguration(groupContainer: .automatic).cloudKitContainerIdentifier
        ?? (context != .live ? "container" : nil)
      var allTables: [any SynchronizableTable] = []
      var allPrivateTables: [any SynchronizableTable] = []
      for table in repeat each tables {
        allTables.append(SynchronizedTable(for: table))
      }
      for privateTable in repeat each privateTables {
        allPrivateTables.append(SynchronizedTable(for: privateTable))
      }
      let userDatabase = UserDatabase(database: database)

      guard context == .live
      else {
        let privateDatabase = MockCloudDatabase(databaseScope: .private)
        let sharedDatabase = MockCloudDatabase(databaseScope: .shared)
        let container = MockCloudContainer(
          containerIdentifier: containerIdentifier ?? "iCloud.co.pointfree.SQLiteData.Tests",
          privateCloudDatabase: privateDatabase,
          sharedCloudDatabase: sharedDatabase
        )
        privateDatabase.set(container: container)
        sharedDatabase.set(container: container)
        try self.init(
          container: container,
          defaultZone: defaultZone,
          defaultSyncEngines: { _, syncEngine in
            (
              private: MockSyncEngine(
                database: privateDatabase,
                parentSyncEngine: syncEngine,
                state: MockSyncEngineState()
              ),
              shared: MockSyncEngine(
                database: sharedDatabase,
                parentSyncEngine: syncEngine,
                state: MockSyncEngineState()
              )
            )
          },
          userDatabase: userDatabase,
          logger: logger,
          delegate: delegate,
          tables: allTables,
          privateTables: allPrivateTables
        )
        try setUpSyncEngine()
        if startImmediately ?? !isTesting {
          _ = try start()
        }
        return
      }

      guard let containerIdentifier else {
        throw SchemaError.noCloudKitContainer
      }

      let container = CKContainer(identifier: containerIdentifier)
      try self.init(
        container: container,
        defaultZone: defaultZone,
        defaultSyncEngines: { metadatabase, syncEngine in
          (
            private: CKSyncEngine(
              CKSyncEngine.Configuration(
                database: container.privateCloudDatabase,
                stateSerialization: try? metadatabase.read { db in
                  try StateSerialization
                    .find(#bind(.private))
                    .select(\.data)
                    .fetchOne(db)
                },
                delegate: syncEngine
              )
            ),
            shared: CKSyncEngine(
              CKSyncEngine.Configuration(
                database: container.sharedCloudDatabase,
                stateSerialization: try? metadatabase.read { db in
                  try StateSerialization
                    .find(#bind(.shared))
                    .select(\.data)
                    .fetchOne(db)
                },
                delegate: syncEngine
              )
            )
          )
        },
        userDatabase: userDatabase,
        logger: logger,
        delegate: delegate,
        tables: allTables,
        privateTables: allPrivateTables
      )
      try setUpSyncEngine()
      if startImmediately ?? !isTesting {
        _ = try start()
      }
    }

    package init(
      container: any CloudContainer,
      defaultZone: CKRecordZone,
      defaultSyncEngines:
        @escaping @Sendable (
          any DatabaseReader,
          SyncEngine
        ) -> (private: any SyncEngineProtocol, shared: any SyncEngineProtocol),
      userDatabase: UserDatabase,
      logger: Logger,
      delegate: (any SyncEngineDelegate)?,
      tables: [any SynchronizableTable],
      privateTables: [any SynchronizableTable] = []
    ) throws {
      let allTables = OrderedSet((tables + privateTables).map(HashableSynchronizedTable.init))
        .map(\.type)
      self.tables = allTables
      self.privateTables = privateTables
      self.delegate = delegate

      let foreignKeysByTableName = Dictionary(
        uniqueKeysWithValues: try userDatabase.read { db in
          try allTables.map { table -> (String, [ForeignKey]) in
            func open<T>(
              _: some SynchronizableTable<T>
            ) throws -> (String, [ForeignKey]) {
              (
                T.tableName,
                try PragmaForeignKeyList<T>
                  .join(PragmaTableInfo<T>.all) { $0.from.eq($1.name) }
                  .select {
                    ForeignKey.Columns(
                      table: $0.table,
                      from: $0.from,
                      to: $0.to,
                      onUpdate: $0.onUpdate,
                      onDelete: $0.onDelete,
                      isNotNull: $1.isNotNull
                    )
                  }
                  .fetchAll(db)
              )
            }
            return try open(table)
          }
        }
      )
      self.container = container
      self.defaultZone = defaultZone
      self.defaultSyncEngines = defaultSyncEngines
      self.userDatabase = userDatabase
      self.logger = logger
      self.metadatabase = try defaultMetadatabase(
        logger: logger,
        url: try URL.metadatabase(
          databasePath: userDatabase.path,
          containerIdentifier: container.containerIdentifier
        ),
        configuration: userDatabase.configuration
      )
      self.tablesByName = Dictionary(
        uniqueKeysWithValues: self.tables.map { ($0.base.tableName, $0) }
      )
      self.foreignKeysByTableName = foreignKeysByTableName
      tablesByOrder = try SQLiteData.tablesByOrder(
        userDatabase: userDatabase,
        tables: allTables,
        tablesByName: tablesByName
      )
      #if os(iOS)
        @Dependency(\.defaultNotificationCenter) var defaultNotificationCenter
        notificationsObserver.withValue {
          $0 = defaultNotificationCenter.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: nil
          ) { [syncEngines] _ in
            _ = Task { @MainActor in
              let taskIdentifier = UIApplication.shared.beginBackgroundTask()
              defer { UIApplication.shared.endBackgroundTask(taskIdentifier) }
              let (privateSyncEngine, sharedSyncEngine) = syncEngines.withValue {
                ($0.private, $0.shared)
              }
              try await privateSyncEngine?.sendChanges(CKSyncEngine.SendChangesOptions())
              try await sharedSyncEngine?.sendChanges(CKSyncEngine.SendChangesOptions())
            }
          }
        }
      #endif
      try validateSchema()
    }

    deinit {
      notificationsObserver.withValue {
        guard let observer = $0
        else { return }
        NotificationCenter.default.removeObserver(observer)
      }
    }

    nonisolated package func setUpSyncEngine() throws {
      try userDatabase.write { db in
        try setUpSyncEngine(writableDB: db)
      }
    }

    nonisolated package func setUpSyncEngine(writableDB db: Database) throws {
      let attachedMetadatabasePath: String? =
        try PragmaDatabaseList
        .where { $0.name.eq(String.sqliteDataCloudKitSchemaName) }
        .select(\.file)
        .fetchOne(db)
      if let attachedMetadatabasePath {
        let metadatabaseName =
          metadatabase.path.isEmpty
          ? try URL.metadatabase(
            databasePath: "",
            containerIdentifier: self.container.containerIdentifier
          )
          .lastPathComponent
          : URL(filePath: metadatabase.path).lastPathComponent
        let attachedMetadatabaseName =
          URL(string: attachedMetadatabasePath)?.lastPathComponent ?? ""
        @Dependency(\.context) var context
        if metadatabaseName != attachedMetadatabaseName
          && !(context == .preview && attachedMetadatabaseName.isEmpty)
        {
          throw SchemaError(
            reason: .metadatabaseMismatch(
              attachedPath: attachedMetadatabasePath,
              syncEngineConfiguredPath: metadatabase.path
            ),
            debugDescription: """
              Metadatabase attached in 'prepareDatabase' does not match metadatabase prepared in \
              'SyncEngine.init'. Are different CloudKit container identifiers being provided?
              """
          )
        }
      } else {
        try #sql(
          """
          ATTACH DATABASE \(bind: metadatabase.path) AS \(quote: .sqliteDataCloudKitSchemaName)
          """
        )
        .execute(db)
      }
      db.add(function: $currentTime)
      db.add(function: SyncEngine.$isSynchronizing)
      db.add(function: $didUpdate)
      db.add(function: $didDelete)
      db.add(function: $hasPermission)
      db.add(function: $currentZoneName)
      db.add(function: $currentOwnerName)

      for trigger in SyncMetadata.callbackTriggers(for: self) {
        try trigger.execute(db)
      }

      for table in tables {
        try table.base.createTriggers(
          foreignKeysByTableName: foreignKeysByTableName,
          tablesByName: tablesByName,
          defaultZone: defaultZone,
          privateTables: privateTables,
          db: db
        )
      }
    }

    /// Starts the sync engine if it is stopped.
    ///
    /// When a sync engine is started it will upload all data stored locally that has not yet
    /// been synchronized to CloudKit, and will download all changes from CloudKit since the
    /// last time it synchronized.
    ///
    /// > Note: By default, sync engines start syncing when initialized.
    public func start() async throws {
      try await start().value
    }

    /// Determines if the sync engine is currently sending local changes to the CloudKit server.
    ///
    /// It is an observable value, which means if it is accessed in a SwiftUI view, or some other
    /// observable context, then the view will automatically re-render when the value changes. As
    /// such, it can be useful for displaying a progress view to indicate that work is currently
    /// being done to synchronize changes.
    public var isSendingChanges: Bool {
      sendingChangesCount > 0
    }

    /// Determines if the sync engine is currently processing changes being sent to the device
    /// from CloudKit.
    ///
    /// It is an observable value, which means if it is accessed in a SwiftUI view, or some other
    /// observable context, then the view will automatically re-render when the value changes. As
    /// such, it can be useful for displaying a progress view to indicate that work is currently
    /// being done to synchronize changes.
    public var isFetchingChanges: Bool {
      fetchingChangesCount > 0
    }

    /// Determines if the sync engine is currently sending or receiving changes from CloudKit.
    ///
    /// This value is true if either of ``isSendingChanges`` or ``isFetchingChanges`` is true.
    /// It is an observable value, which means if it is accessed in a SwiftUI view, or some other
    /// observable context, then the view will automatically re-render when the value changes. As
    /// such, it can be useful for displaying a progress view to indicate that work is currently
    /// being done to synchronize changes.
    public var isSynchronizing: Bool {
      isSendingChanges || isFetchingChanges
    }

    /// Stops the sync engine if it is running.
    ///
    /// All edits made after stopping the sync engine will not be synchronized to CloudKit.
    /// You must start the sync engine again using ``start()`` to synchronize the changes.
    public func stop() {
      let (isStarting, runningGeneration) = startup.withValue { startup in
        let isStarting = startup.pending?.generation == startup.generation
        // NB: A start still creating its sync engines throws them away once they are created.
        startup.generation += 1
        return (
          isStarting,
          syncEngines.withValue(\.isRunning) ? startup.generation : nil
        )
      }
      guard isStarting || runningGeneration != nil
      else { return }
      #if DEBUG && canImport(DeveloperToolsSupport)
        previewTimerTask.withValue {
          $0?.cancel()
          $0 = nil
        }
      #endif
      guard let runningGeneration
      else { return }
      observationRegistrar.withMutation(of: self, keyPath: \.isRunning) {
        startup.withValue { startup in
          // NB: Another stop since, and maybe a start after it, has the last word.
          guard startup.generation == runningGeneration
          else { return }
          syncEngines.withValue {
            $0 = SyncEngines()
          }
        }
      }
    }

    /// Determines if the sync engine is currently running or not.
    public var isRunning: Bool {
      observationRegistrar.access(self, keyPath: \.isRunning)
      return syncEngines.withValue {
        $0.isRunning
      }
    }

    /// Starts the sync engine, unless it is running or starting.
    ///
    /// `CKSyncEngine` decodes the state saved by the previous launch when it is created, and the
    /// state holds every change still waiting to be sent: 15 MB took 13 to 14 seconds on one
    /// iPhone, and 30 on an iPhone 12 mini. So the sync engines are created on a task, and put in
    /// place under the lock of
    /// `syncEngines` only once they exist. Nothing waits for them: not checking whether sync is
    /// running, not saving a change (a trigger checks it), not stopping sync, and not the app
    /// leaving the foreground, all of which can happen on the main thread.
    ///
    /// - Returns: The task of the start, which ends once sync is running and has queued the
    ///   changes waiting to be sent, or once a stop called the start off.
    private func start() throws -> Task<Void, Never> {
      if let task = startup.withValue({ currentStartTask(startup: $0) }) {
        return task
      }

      let previousRecordTypes = try metadatabase.read { db in
        try RecordType.all.fetchAll(db)
      }
      let currentRecordTypes = try userDatabase.read { db in
        let namesAndSchemas =
          try SQLiteSchema
          .where {
            $0.type.eq(#bind(.table))
              && $0.tableName.in(tables.map { $0.base.tableName })
          }
          .fetchAll(db)
        return try namesAndSchemas.compactMap { schema -> RecordType? in
          guard let sql = schema.sql, let table = tablesByName[schema.name]
          else { return nil }
          func open<T>(_: some SynchronizableTable<T>) throws -> RecordType {
            try RecordType(
              tableName: schema.name,
              schema: sql,
              tableInfo: Set(
                PragmaTableInfo<T>
                  .select {
                    TableInfo.Columns(
                      defaultValue: $0.defaultValue,
                      isPrimaryKey: $0.isPrimaryKey,
                      name: $0.name,
                      isNotNull: $0.isNotNull,
                      type: $0.type
                    )
                  }
                  .fetchAll(db)
              )
            )
          }
          return try open(table)
        }
      }
      let previousRecordTypeByTableName = Dictionary(
        uniqueKeysWithValues: previousRecordTypes.map {
          ($0.tableName, $0)
        }
      )
      let currentRecordTypeByTableName = Dictionary(
        uniqueKeysWithValues: currentRecordTypes.map {
          ($0.tableName, $0)
        }
      )

      let (startTask, isNewStart) = startup.withValue {
        startup -> (Task<Void, Never>, Bool) in
        if let task = currentStartTask(startup: startup) {
          return (task, false)
        }
        let generation = startup.generation
        let previousCreation = startup.pending?.creation
        let creation = Task<Bool, Never> {
          // NB: A start that a stop called off may still be creating its sync engines, and
          //     CloudKit expects one sync engine per database.
          _ = await previousCreation?.value
          let (privateSyncEngine, sharedSyncEngine) = defaultSyncEngines(metadatabase, self)
          return observationRegistrar.withMutation(of: self, keyPath: \.isRunning) {
            self.startup.withValue { startup in
              if startup.pending?.generation == generation {
                startup.pending = nil
              }
              guard startup.generation == generation
              else { return false }
              syncEngines.withValue {
                $0 = SyncEngines(
                  private: privateSyncEngine,
                  shared: sharedSyncEngine
                )
              }
              return true
            }
          }
        }
        let startTask = Task<Void, Never> {
          guard await creation.value
          else { return }
          await withErrorReporting(.sqliteDataCloudKitFailure) {
            guard try await container.accountStatus() == .available
            else { return }
            runningSyncEngines()?.private.state
              .add(pendingDatabaseChanges: [.saveZone(defaultZone)])
            try await uploadRecordsToCloudKit(
              previousRecordTypeByTableName: previousRecordTypeByTableName,
              currentRecordTypeByTableName: currentRecordTypeByTableName
            )
            try await updateLocalFromSchemaChange(
              previousRecordTypeByTableName: previousRecordTypeByTableName,
              currentRecordTypeByTableName: currentRecordTypeByTableName
            )
            try await cacheUserTables(recordTypes: currentRecordTypes)
          }
        }
        startup.pending = PendingStart(
          generation: generation,
          creation: creation,
          task: startTask
        )
        // NB: Set before the engines exist, so that fetching and sending changes wait for them.
        self.startTask.withValue {
          $0?.cancel()
          $0 = startTask
        }
        return (startTask, true)
      }
      guard isNewStart
      else { return startTask }

      #if DEBUG && canImport(DeveloperToolsSupport)
        @Dependency(\.context) var context
        @Dependency(\.continuousClock) var clock
        if context == .preview {
          previewTimerTask.withValue {
            $0?.cancel()
            $0 = Task { @Sendable [weak self] in
              await withErrorReporting {
                while true {
                  guard let self else { break }
                  try await clock.sleep(for: .seconds(1))
                  try await self.syncChanges()
                }
              }
            }
          }
        }
      #endif
      return startTask
    }

    /// The task of the start in progress, or a finished task when sync is running.
    private func currentStartTask(startup: Startup) -> Task<Void, Never>? {
      if let pending = startup.pending, pending.generation == startup.generation {
        return pending.task
      }
      guard syncEngines.withValue(\.isRunning)
      else { return nil }
      return Task {}
    }

    /// Waits until the sync engines being created, if any, are in place or thrown away.
    func engineCreation() async {
      _ = await startup.withValue { $0.pending?.creation }?.value
    }

    /// Fetches pending remote changes from the server.
    ///
    /// Use this method to ensure the sync engine immediately fetches all pending remote changes
    /// before your app continues. This isn't necessary in normal use, as the engine automatically
    /// syncs your app's records. It is useful, however, in scenarios where you require more control
    /// over sync, such as pull-to-refresh.
    ///
    /// - Parameter options: The options to use when fetching changes.
    public func fetchChanges(
      _ options: CKSyncEngine.FetchChangesOptions = CKSyncEngine.FetchChangesOptions()
    ) async throws {
      await startTask.withValue(\.self)?.value
      let (privateSyncEngine, sharedSyncEngine) = syncEngines.withValue {
        ($0.private, $0.shared)
      }
      guard let privateSyncEngine, let sharedSyncEngine
      else { return }
      async let `private`: Void = privateSyncEngine.fetchChanges(options)
      async let shared: Void = sharedSyncEngine.fetchChanges(options)
      _ = try await (`private`, shared)
    }

    /// Sends pending local changes to the server.
    ///
    /// Use this method to ensure the sync engine sends all pending local changes to the server
    /// before your app continues. This isn't necessary in normal use, as the engine automatically
    /// syncs your app's records. It is useful, however, in scenarios where you require greater
    /// control over sync, such as a "Backup now" button.
    ///
    /// - Parameter options: The options to use when sending changes.
    public func sendChanges(
      _ options: CKSyncEngine.SendChangesOptions = CKSyncEngine.SendChangesOptions()
    ) async throws {
      await startTask.withValue(\.self)?.value
      let (privateSyncEngine, sharedSyncEngine) = syncEngines.withValue {
        ($0.private, $0.shared)
      }
      guard let privateSyncEngine, let sharedSyncEngine
      else { return }
      privateSyncEngine.state.hasPendingUntrackedChanges = true
      sharedSyncEngine.state.hasPendingUntrackedChanges = true
      defer {
        privateSyncEngine.state.hasPendingUntrackedChanges = false
        sharedSyncEngine.state.hasPendingUntrackedChanges = false
      }
      async let `private`: Void = privateSyncEngine.sendChanges(options)
      async let shared: Void = sharedSyncEngine.sendChanges(options)
      _ = try await (`private`, shared)
    }

    /// Synchronizes local and remote pending changes.
    ///
    /// Use this method to ensure the sync engine immediately fetches all pending remote changes
    /// _and_ sends all pending local changes to the server. This isn't necessary in normal use,
    /// as the engine automatically syncs your app's records. It is useful, however, in scenarios
    /// where you require greater control over sync.
    ///
    /// - Parameters:
    ///   - fetchOptions: The options to use when fetching changes.
    ///   - sendOptions: The options to use when sending changes.
    public func syncChanges(
      fetchOptions: CKSyncEngine.FetchChangesOptions = CKSyncEngine.FetchChangesOptions(),
      sendOptions: CKSyncEngine.SendChangesOptions = CKSyncEngine.SendChangesOptions()
    ) async throws {
      try await sendChanges(sendOptions)
      try await fetchChanges(fetchOptions)
    }

    private func cacheUserTables(recordTypes: [RecordType]) async throws {
      try await userDatabase.write { db in
        try RecordType
          .upsert { recordTypes.map { RecordType.Draft($0) } }
          .execute(db)
      }
    }

    private func uploadRecordsToCloudKit(
      previousRecordTypeByTableName: [String: RecordType],
      currentRecordTypeByTableName: [String: RecordType]
    ) async throws {
      try await enqueueLocallyPendingChanges()
      try await settleUnconfirmedDeletions()
      try await userDatabase.write { db in
        let newTableNames = currentRecordTypeByTableName.keys.filter { tableName in
          previousRecordTypeByTableName[tableName] == nil
        }

        try $_isSynchronizingChanges.withValue(false) {
          for tableName in newTableNames {
            try self.uploadRecordsToCloudKit(tableName: tableName, db: db)
          }
        }
      }
    }

    /// Queues the changes saved while sync wasn't running, from the notes `noteForNextStart`
    /// left, and the saves parked when iCloud's storage was full.
    ///
    /// The notes are read, queued and removed in one write. A note is written in a write too, which
    /// queues the change itself when sync is running, so each change is queued once: by the start
    /// that reads its note, or directly. A change noted after this write waits for the next start.
    ///
    /// - Parameter scope: The database whose changes to queue, or `nil` for every change, including
    ///   those noted before changes recorded their database.
    private func enqueueLocallyPendingChanges(scope: CKDatabase.Scope? = nil) async throws {
      try await userDatabase.write { db in
        let changesInScope = PendingRecordZoneChange.where {
          $0.databaseScope.is(#bind(scope))
            .or(#bind(scope, as: CKDatabase.Scope?.RawRepresentation.self).is(nil))
        }
        let pendingRecordZoneChanges =
          try changesInScope
          .select(\.pendingRecordZoneChange)
          .fetchAll(db)
        guard !pendingRecordZoneChanges.isEmpty
        else { return }
        // NB: When sync stopped since this start began, the notes wait for the next start.
        guard queueWithRunningEngines(pendingRecordZoneChanges)
        else { return }
        try changesInScope.delete().execute(db)
      }
    }

    /// Queues changes with the running sync engines, each one with the engine of its record's
    /// database.
    ///
    /// - Returns: Whether sync is running. When it isn't, nothing is queued.
    private func queueWithRunningEngines(
      _ changes: [CKSyncEngine.PendingRecordZoneChange]
    ) -> Bool {
      guard let (privateSyncEngine, sharedSyncEngine) = runningSyncEngines()
      else { return false }
      let changesByIsPrivate = Dictionary(grouping: changes) {
        switch $0 {
        case .deleteRecord(let recordID), .saveRecord(let recordID):
          recordID.zoneID.ownerName == CKCurrentUserDefaultName
        @unknown default:
          false
        }
      }
      if let changes = changesByIsPrivate[true] {
        privateSyncEngine.state.add(pendingRecordZoneChanges: changes)
      }
      if let changes = changesByIsPrivate[false] {
        sharedSyncEngine.state.add(pendingRecordZoneChanges: changes)
      }
      return true
    }

    /// The running sync engines, or nil when sync isn't running.
    ///
    /// They are taken under the lock of `syncEngines`, and their state is then read and changed
    /// outside of it. With a large queue, `CKSyncEngine` can take hundreds of milliseconds over its
    /// state (it saves the whole queue every time it changes: about 400 ms for 40 MB in the
    /// simulator), and `isRunning`, which the main thread reads, takes that lock.
    private func runningSyncEngines() -> (
      private: any SyncEngineProtocol, shared: any SyncEngineProtocol
    )? {
      syncEngines.withValue { syncEngines in
        guard syncEngines.isRunning,
          let privateSyncEngine = syncEngines.private,
          let sharedSyncEngine = syncEngines.shared
        else { return nil }
        return (privateSyncEngine, sharedSyncEngine)
      }
    }

    /// Notes changes saved while sync isn't running, for the next start to queue.
    ///
    /// The note is written after the write that saved the changes, which a trigger can't do, on a
    /// task. Sync may have started in the meantime, and its start may have read the notes already
    /// (see `enqueueLocallyPendingChanges`). So the write checks again, and queues the changes
    /// directly once sync is running.
    private func noteForNextStart(_ changes: [CKSyncEngine.PendingRecordZoneChange]) {
      // TODO: Perform this work in a trigger instead of a task.
      Task {
        await withErrorReporting(.sqliteDataCloudKitFailure) {
          try await userDatabase.write { db in
            guard !queueWithRunningEngines(changes)
            else { return }
            try PendingRecordZoneChange
              .insert {
                changes.map { change in
                  PendingRecordZoneChange(
                    change,
                    databaseScope: change.id?.zoneID.databaseScope
                  )
                }
              }
              .execute(db)
          }
        }
      }
    }

    /// Settles the local deletions CloudKit hasn't confirmed, when the engine starts.
    ///
    /// A deletion keeps its metadata, flagged with `_isDeleted`, until it leaves the queue (see
    /// `removeDeletionMetadata`). Two things can leave that metadata wrong: the row is back on the
    /// device (see `settleReturnedRows`), or the deletion is missing from the queue, which lives in
    /// CKSyncEngine's saved state and can be lost (see `settleLostDeletions`).
    ///
    /// Called after the changes made while the engine was stopped are queued, so that a deletion
    /// queued then counts as queued.
    private func settleUnconfirmedDeletions() async throws {
      // NB: No index covers '_isDeleted', so the deletions are found on a reader, where the scan
      //     cannot hold up writes. Each step checks the flag again in the write that acts on it.
      let recordNames = try await metadatabase.read { db in
        try SyncMetadata
          .where(\._isDeleted)
          .select(\.recordName)
          .fetchAll(db)
      }
      guard !recordNames.isEmpty
      else { return }
      try await settleReturnedRows(recordNames: recordNames)
      try await settleLostDeletions(recordNames: recordNames)
    }

    /// Settles the rows that are on the device although their metadata is flagged `_isDeleted`.
    ///
    /// Older versions left such rows behind: a fetch wrote a deleted row back when its deletion
    /// hadn't been sent yet, and writing a row again with the same primary key left its flag on.
    /// The person deleted the row, so it is deleted again, with everything under it, on this
    /// device and in iCloud, the way a deletion the person makes now is.
    ///
    /// A row someone took back after it returned stays: one that holds a change the server never
    /// received, or that has a row under it the deletion didn't take (one added since, here or on
    /// another device), or one that stays. Its flag goes, and with it any deletion of it, or of
    /// its share, still queued. It is fetched again, for the edits fetches skipped while it was
    /// flagged, and its change is uploaded. A row whose deletion SQLite refuses (one in a share
    /// this user can no longer change) stays the same way.
    private func settleReturnedRows(recordNames: [String]) async throws {
      let keptRows = try await userDatabase.write { db in
        var returnedRows: [ReturnedRow] = []
        let flaggedMetadata =
          try SyncMetadata
          .where { $0.recordName.in(recordNames) && $0._isDeleted }
          .fetchAll(db)
        for metadata in flaggedMetadata {
          guard let isChanged = try hasUnsentChange(metadata, db: db)
          else { continue }
          returnedRows.append(
            ReturnedRow(metadata: metadata, isChanged: isChanged, isKept: isChanged)
          )
        }
        guard !returnedRows.isEmpty
        else { return returnedRows }

        // NB: Deleting the row deletes the rows under it. The deletion flagged every row it took,
        //     so a row under it without a flag came after it.
        var rowsUnderByRecordName: [String: Set<String>] = [:]
        for index in returnedRows.indices {
          let metadata = returnedRows[index].metadata
          let rowsUnder = try dependentRows(
            of: [metadata.recordType: [metadata.recordPrimaryKey]],
            db: db
          )
          .deletedRecordNames
          rowsUnderByRecordName[metadata.recordName] = rowsUnder
          let flaggedCount =
            try SyncMetadata
            .where { $0.recordName.in(Array(rowsUnder)) && $0._isDeleted }
            .fetchCount(db)
          if flaggedCount < rowsUnder.count {
            returnedRows[index].isKept = true
          }
        }
        while true {
          let keptRecordNames = Set(returnedRows.filter(\.isKept).map(\.metadata.recordName))
          let newlyKept = returnedRows.indices.filter {
            !returnedRows[$0].isKept
              && !(rowsUnderByRecordName[returnedRows[$0].metadata.recordName] ?? [])
                .isDisjoint(with: keptRecordNames)
          }
          guard !newlyKept.isEmpty
          else { break }
          for index in newlyKept {
            returnedRows[index].isKept = true
          }
        }

        // NB: Written as the sync engine, so no trigger queues anything.
        try SyncMetadata
          .where { $0.recordName.in(returnedRows.map(\.metadata.recordName)) }
          .update { $0._isDeleted = false }
          .execute(db)

        // NB: Deleted as the person deletes a row, so that the triggers flag it and everything
        //     under it, and queue their deletions.
        var keptRows = returnedRows.filter(\.isKept)
        for returnedRow in returnedRows where !returnedRow.isKept {
          guard let table = tablesByName[returnedRow.metadata.recordType]
          else { continue }
          func open<T>(_: some SynchronizableTable<T>) throws {
            try T
              .unscoped
              .where { #sql("\($0.primaryKey) = \(bind: returnedRow.metadata.recordPrimaryKey)") }
              .delete()
              .execute(db)
          }
          do {
            try db.inSavepoint {
              try $_isSynchronizingChanges.withValue(false) {
                try open(table)
              }
              return .commit
            }
          } catch {
            keptRows.append(returnedRow)
          }
        }
        guard !keptRows.isEmpty
        else { return keptRows }

        // NB: The saves are queued once the rows have been fetched again, so that they are built
        //     on the current records.
        try SyncMetadata
          .where { $0.recordName.in(keptRows.filter(\.isChanged).map(\.metadata.recordName)) }
          .update { $0.userModificationTime = $currentTime() }
          .execute(db)
        try UnsyncedRecordID
          .insert { keptRows.map { UnsyncedRecordID(recordID: $0.recordID) } }
          onConflictDoUpdate: { _ in }
          .execute(db)
        return keptRows
      }
      guard !keptRows.isEmpty
      else { return }

      if let syncEngines = runningSyncEngines() {
        for keptRow in keptRows {
          let syncEngine =
            keptRow.recordID.zoneID.ownerName == CKCurrentUserDefaultName
            ? syncEngines.private
            : syncEngines.shared
          syncEngine.state.remove(
            pendingRecordZoneChanges: keptRow.deletionRecordIDs.map { .deleteRecord($0) }
          )
        }
      }

      // NB: Fetches the kept rows again, as queued in 'UnsyncedRecordID'. A row whose record is
      //     gone from the server stays until the fetch that delivers its deletion.
      for isPrivate in Set(keptRows.map(\.isPrivate)).sorted(by: { $0 && !$1 }) {
        guard let syncEngine = syncEngines.withValue({ isPrivate ? $0.private : $0.shared })
        else { continue }
        await handleFetchedRecordZoneChanges(syncEngine: syncEngine)
      }

      if let syncEngines = runningSyncEngines() {
        for keptRow in keptRows where keptRow.isChanged {
          let syncEngine = keptRow.isPrivate ? syncEngines.private : syncEngines.shared
          syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(keptRow.recordID)])
        }
      }
    }

    /// The rows a delete of other rows reaches through foreign keys, read before the delete.
    ///
    /// SQLite deletes the rows under a deleted row (`ON DELETE CASCADE`, at every level below it),
    /// and clears the reference of others (`ON DELETE SET NULL` or `SET DEFAULT`).
    ///
    /// - Parameter rows: Primary keys, as the metadata stores them, by table name.
    private func dependentRows(
      of rows: [String: Set<String>],
      db: Database
    ) throws -> DependentRows {
      var dependentRows = DependentRows()
      var reached = rows
      var pending = Array(rows)
      while let (parentTableName, parentPrimaryKeys) = pending.popLast() {
        guard
          !parentPrimaryKeys.isEmpty,
          let parentPrimaryKey = primaryKeyName(of: parentTableName)
        else { continue }
        let parentPrimaryKeys = Array(parentPrimaryKeys)
        for (childTableName, foreignKeys) in foreignKeysByTableName {
          guard let childPrimaryKey = primaryKeyName(of: childTableName)
          else { continue }
          for foreignKey in foreignKeys where foreignKey.table == parentTableName {
            let isDeleted: Bool
            switch foreignKey.onDelete {
            case .cascade:
              isDeleted = true
            case .setNull, .setDefault:
              isDeleted = false
            case .restrict, .noAction:
              continue
            }
            let parentColumn = foreignKey.to.isEmpty ? parentPrimaryKey : foreignKey.to
            var childPrimaryKeys: Set<String> = []
            for start in stride(from: 0, to: parentPrimaryKeys.count, by: 500) {
              let batch = Array(parentPrimaryKeys[start..<min(start + 500, parentPrimaryKeys.count)])
              childPrimaryKeys.formUnion(
                try String.fetchAll(
                  db,
                  sql: """
                    SELECT CAST(\(childPrimaryKey.quotedDatabaseIdentifier) AS TEXT)
                    FROM \(childTableName.quotedDatabaseIdentifier)
                    WHERE \(foreignKey.from.quotedDatabaseIdentifier) IN (
                      SELECT \(parentColumn.quotedDatabaseIdentifier)
                      FROM \(parentTableName.quotedDatabaseIdentifier)
                      WHERE \(parentPrimaryKey.quotedDatabaseIdentifier) \
                      IN (\(databaseQuestionMarks(count: batch.count)))
                    )
                    """,
                  arguments: StatementArguments(batch)
                )
              )
            }
            if isDeleted {
              let newPrimaryKeys = childPrimaryKeys.subtracting(reached[childTableName] ?? [])
              guard !newPrimaryKeys.isEmpty
              else { continue }
              reached[childTableName, default: []].formUnion(newPrimaryKeys)
              dependentRows.deleted[childTableName, default: []].formUnion(newPrimaryKeys)
              pending.append((childTableName, newPrimaryKeys))
            } else if !childPrimaryKeys.isEmpty {
              dependentRows.changed[childTableName, default: []].formUnion(childPrimaryKeys)
            }
          }
        }
      }
      // NB: A row that is both deleted and changed is deleted.
      for (tableName, primaryKeys) in dependentRows.deleted {
        dependentRows.changed[tableName]?.subtract(primaryKeys)
      }
      return dependentRows
    }

    private func primaryKeyName(of tableName: String) -> String? {
      guard let table = tablesByName[tableName]
      else { return nil }
      func open<T>(_: some SynchronizableTable<T>) -> String {
        T.primaryKey.name
      }
      return open(table)
    }

    /// Whether the row of this metadata holds a change the server never received, or `nil` when
    /// the row isn't on the device.
    private func hasUnsentChange(_ metadata: SyncMetadata, db: Database) throws -> Bool? {
      guard let table = tablesByName[metadata.recordType]
      else { return nil }
      func open<T>(_: some SynchronizableTable<T>) throws -> Bool? {
        let row =
          try T
          .unscoped
          .where { #sql("\($0.primaryKey) = \(bind: metadata.recordPrimaryKey)") }
          .fetchOne(db)
        guard let row
        else { return nil }
        guard
          metadata.lastKnownServerRecord?.hasServerChangeTag == true,
          let allFields = metadata._lastKnownServerRecordAllFields
        else { return true }
        return allFields.isModified(by: T(queryOutput: row))
      }
      return try open(table)
    }

    /// Settles the local deletions that are missing from the queue.
    ///
    /// The queue lives in CKSyncEngine's saved state, which can be lost, or saved before a
    /// deletion was queued, and a deletion missing from it is never sent. A deletion is what the
    /// person asked for, so it is sent all the same, once a fetch has brought in the other
    /// devices' changes, even when another device carried on with what it deleted meanwhile. Each
    /// deletion (a flagged record with the flagged records under it, all taken by one local
    /// delete) is checked against iCloud:
    ///
    /// * Its records still on the server are deleted again, edited elsewhere or not.
    /// * The records another device added under them go too. They wait on this device for their
    ///   missing parent (see `upsertFromServerRecord`). CloudKit refuses to delete a record while
    ///   another one points at it as its parent ("Record delete would violate validating
    ///   reference"), and a link, which points at its rows only through plain values, would
    ///   otherwise stay on the server, pointing at nothing, on every device.
    /// * A record no longer on the server needs nothing more, and neither does one that never
    ///   reached it.
    /// * When iCloud can't be reached, it waits for the next start.
    private func settleLostDeletions(recordNames: [String]) async throws {
      let runningEngines = runningSyncEngines()
      let queuedDeletionRecordIDs = Set(
        ((runningEngines?.private.state.pendingRecordZoneChanges ?? [])
          + (runningEngines?.shared.state.pendingRecordZoneChanges ?? []))
          .compactMap { change -> CKRecord.ID? in
            guard case .deleteRecord(let recordID) = change
            else { return nil }
            return recordID
          }
      )
      func lostDeletions() async throws -> [SyncMetadata] {
        try await metadatabase.read { db in
          try SyncMetadata
            .where { $0.recordName.in(recordNames) && $0._isDeleted }
            .fetchAll(db)
        }
        .filter { !$0.deletionRecordIDs.contains(where: queuedDeletionRecordIDs.contains) }
      }

      // NB: A record that never reached the server has nothing there to delete.
      let neverSentRecordNames = try await lostDeletions()
        .filter { $0.lastKnownServerRecord == nil }
        .map { $0.recordName }
      if !neverSentRecordNames.isEmpty {
        try await userDatabase.write { db in
          try SyncMetadata
            .where { $0.recordName.in(neverSentRecordNames) && $0._isDeleted }
            .delete()
            .execute(db)
        }
      }
      guard !(try await lostDeletions()).isEmpty
      else { return }

      // NB: Fetches first, so that the records other devices added under the deleted ones are on
      //     this device, waiting for their parents, and the deletions they already sent are applied.
      do {
        for syncEngine in syncEngines.withValue({ [$0.private, $0.shared] }) {
          try await syncEngine?.fetchChanges(CKSyncEngine.FetchChangesOptions())
        }
      } catch {
        return
      }
      let lostMetadata = try await lostDeletions()
      guard !lostMetadata.isEmpty
      else { return }

      let serverResults: [CKRecord.ID: Result<CKRecord, any Error>]
      let waitingRecordResults: [CKRecord.ID: Result<CKRecord, any Error>]
      do {
        serverResults = try await serverRecords(for: lostMetadata.map { $0.zonedRecordID })
        let unsyncedRecordIDs = try await metadatabase.read { db in
          try UnsyncedRecordID.all.fetchAll(db).map(CKRecord.ID.init(unsyncedRecordID:))
        }
        waitingRecordResults = try await serverRecords(for: unsyncedRecordIDs)
      } catch {
        return
      }
      var waitingRecords: [CKRecord] = []
      for result in waitingRecordResults.values {
        switch result {
        case .success(let record):
          waitingRecords.append(record)
        case .failure(let error as CKError) where error.code == .unknownItem:
          continue
        case .failure:
          // NB: A record waiting for a parent this device can't tell.
          return
        }
      }

      var goneRecordNames: [String] = []
      var uncheckedRecordNames: Set<String> = []
      var serverRecordsByName: [String: CKRecord] = [:]
      for metadata in lostMetadata {
        switch serverResults[metadata.zonedRecordID] {
        case .success(let record):
          serverRecordsByName[metadata.recordName] = record
        case .failure(let error as CKError)
        where error.code == .unknownItem || error.code == .zoneNotFound:
          goneRecordNames.append(metadata.recordName)
        case .failure, nil:
          uncheckedRecordNames.insert(metadata.recordName)
        }
      }

      let lostMetadataByRecordName = Dictionary(
        lostMetadata.map { ($0.recordName, $0) },
        uniquingKeysWith: { first, _ in first }
      )
      func deletedRoot(of recordName: String) -> String {
        var recordName = recordName
        var visitedRecordNames: Set<String> = [recordName]
        while let parentRecordName = lostMetadataByRecordName[recordName]?.parentRecordName,
          lostMetadataByRecordName[parentRecordName] != nil,
          visitedRecordNames.insert(parentRecordName).inserted
        {
          recordName = parentRecordName
        }
        return recordName
      }
      var deletedRecordNames: Set<String> = []
      var resentRecordNames: [String] = []
      for deletion in Dictionary(grouping: lostMetadata, by: { deletedRoot(of: $0.recordName) })
        .values
      {
        guard !deletion.contains(where: { uncheckedRecordNames.contains($0.recordName) })
        else { continue }
        deletedRecordNames.formUnion(deletion.map(\.recordName))
        resentRecordNames.append(
          contentsOf: deletion.map(\.recordName).filter { serverRecordsByName[$0] != nil }
        )
      }

      // NB: Records under records under the deleted ones go too, at every level.
      var recordsUnderDeletions: [CKRecord] = []
      var remainingWaitingRecords = waitingRecords
      while true {
        let (under, rest) = remainingWaitingRecords.reduce(into: ([CKRecord](), [CKRecord]())) {
          if parentRecordNames(of: $1).isDisjoint(with: deletedRecordNames) {
            $0.1.append($1)
          } else {
            $0.0.append($1)
          }
        }
        guard !under.isEmpty
        else { break }
        recordsUnderDeletions.append(contentsOf: under)
        deletedRecordNames.formUnion(under.map(\.recordID.recordName))
        remainingWaitingRecords = rest
      }

      try await userDatabase.write { [goneRecordNames, resentRecordNames] db in
        try SyncMetadata
          .where { $0.recordName.in(goneRecordNames) && $0._isDeleted }
          .delete()
          .execute(db)

        // NB: Queued in a write, which cannot interleave with the confirmation of one of them: a
        //     deletion confirmed in the meantime has lost its flag.
        let resentMetadata =
          try SyncMetadata
          .where { $0.recordName.in(resentRecordNames) && $0._isDeleted }
          .fetchAll(db)
        var privateChanges: [CKSyncEngine.PendingRecordZoneChange] = []
        var sharedChanges: [CKSyncEngine.PendingRecordZoneChange] = []
        for metadata in resentMetadata {
          // NB: The same changes, and the same engine, as 'didDelete' queued them.
          let zoneID = metadata.lastKnownServerRecord?.recordID.zoneID ?? metadata.zonedRecordID.zoneID
          var changes: [CKSyncEngine.PendingRecordZoneChange] = [
            .deleteRecord(CKRecord.ID(recordName: metadata.recordName, zoneID: zoneID))
          ]
          if let share = metadata.share {
            changes.append(.deleteRecord(share.recordID))
          }
          if zoneID.ownerName == CKCurrentUserDefaultName {
            privateChanges.append(contentsOf: changes)
          } else {
            sharedChanges.append(contentsOf: changes)
          }
        }
        if let syncEngines = runningSyncEngines() {
          syncEngines.private.state.add(pendingRecordZoneChanges: privateChanges)
          syncEngines.shared.state.add(pendingRecordZoneChanges: sharedChanges)
        }
      }
      try await deleteRecordsNotOnDevice(recordsUnderDeletions)
    }

    /// Deletes records in iCloud that have no row on this device, as `didDelete` deletes one that
    /// had.
    ///
    /// Each one keeps its metadata, flagged `_isDeleted`, until CloudKit confirms the deletion
    /// (see `removeDeletionMetadata`), so that no fetch writes it back in the meantime, and it no
    /// longer waits for a parent.
    private func deleteRecordsNotOnDevice(_ records: [CKRecord]) async throws {
      let deletedMetadata = try await userDatabase.write { db in
        var deletedMetadata: [SyncMetadata] = []
        for record in records {
          guard let recordPrimaryKey = record.recordID.recordPrimaryKey
          else { continue }
          try SyncMetadata.insert {
            SyncMetadata(
              recordPrimaryKey: recordPrimaryKey,
              recordType: record.recordType,
              zoneName: record.recordID.zoneID.zoneName,
              ownerName: record.recordID.zoneID.ownerName,
              parentRecordPrimaryKey: record.parent?.recordID.recordPrimaryKey,
              parentRecordType: record.parent?.recordID.tableName,
              lastKnownServerRecord: record,
              _lastKnownServerRecordAllFields: record,
              share: nil,
              userModificationTime: record.userModificationTime
            )
          } onConflict: {
            ($0.recordPrimaryKey, $0.recordType)
          } doUpdate: {
            $0.setLastKnownServerRecord(record)
          }
          .execute(db)
          try SyncMetadata
            .find(record.recordID)
            .update { $0._isDeleted = true }
            .execute(db)
          try UnsyncedRecordID.find(record.recordID).delete().execute(db)
          if let metadata = try SyncMetadata.find(record.recordID).fetchOne(db) {
            deletedMetadata.append(metadata)
          }
        }
        return deletedMetadata
      }
      for metadata in deletedMetadata {
        didDelete(
          recordName: metadata.recordName,
          record: metadata.lastKnownServerRecord,
          share: metadata.share
        )
      }
    }

    /// Fetches records from the database each one is in, in batches CloudKit accepts, waiting and
    /// trying again when CloudKit limits the rate of requests.
    private func serverRecords(
      for recordIDs: [CKRecord.ID]
    ) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
      var results: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
      let recordIDsByIsPrivate = Dictionary(grouping: recordIDs) {
        $0.zoneID.ownerName == CKCurrentUserDefaultName
      }
      for (isPrivate, recordIDs) in recordIDsByIsPrivate {
        guard let syncEngine = syncEngines.withValue({ isPrivate ? $0.private : $0.shared })
        else { throw CKError(.notAuthenticated) }
        try await syncEngine.database.records(for: recordIDs) { batchResults in
          results.merge(batchResults, uniquingKeysWith: { _, result in result })
        }
      }
      return results
    }

    /// The names of the records a record points at: its parent, and every row its foreign keys
    /// reference.
    private func parentRecordNames(of record: CKRecord) -> Set<String> {
      var recordNames: Set<String> = []
      if let parent = record.parent {
        recordNames.insert(parent.recordID.recordName)
      }
      for foreignKey in foreignKeysByTableName[record.recordType] ?? [] {
        if let recordName = referencedRecordName(of: record, through: foreignKey) {
          recordNames.insert(recordName)
        }
      }
      return recordNames
    }

    /// The name of the record a foreign key of a record points at, or `nil` when it is empty.
    private func referencedRecordName(
      of record: CKRecord,
      through foreignKey: ForeignKey
    ) -> String? {
      switch record.encryptedValues[foreignKey.from] {
      case let value as String:
        "\(value):\(foreignKey.table)"
      case let value as NSNumber:
        "\(value.stringValue):\(foreignKey.table)"
      default:
        nil
      }
    }

    private func enqueueUnknownRecordsForCloudKit() async throws {
      try await userDatabase.write { db in
        try $_isSynchronizingChanges.withValue(false) {
          // NB: Touching the metadata of a record deleted locally would queue a save of it, and
          //     CKSyncEngine discards a pending deletion when a save of the same record follows it.
          try SyncMetadata
            .where { !$0.hasLastKnownServerRecord && !$0._isDeleted }
            .update { $0.recordPrimaryKey = $0.recordPrimaryKey }
            .execute(db)
        }
      }
    }

    private func uploadRecordsToCloudKit<T>(
      table: some SynchronizableTable<T>,
      db: Database
    ) throws {
      // try T.update { $0.primaryKey = $0.primaryKey }.execute(db)
      try #sql(
        """
        UPDATE \(T.self) SET \(quote: T.primaryKey.name) = \(quote: T.primaryKey.name)
        """
      )
      .execute(db)
    }

    private func uploadRecordsToCloudKit(tableName: String, db: Database) throws {
      guard let table = self.tablesByName[tableName]
      else { return }
      func open<T>(_ table: some SynchronizableTable<T>) throws {
        try uploadRecordsToCloudKit(table: table, db: db)
      }
      try open(table)
    }

    private func updateLocalFromSchemaChange(
      previousRecordTypeByTableName: [String: RecordType],
      currentRecordTypeByTableName: [String: RecordType]
    ) async throws {
      let tablesWithChangedSchemas = currentRecordTypeByTableName.filter { tableName, recordType in
        previousRecordTypeByTableName[tableName]?.schema != recordType.schema
      }

      for (tableName, currentRecordType) in tablesWithChangedSchemas {
        guard let table = tablesByName[tableName]
        else { continue }
        func open<T>(_ table: some SynchronizableTable<T>) async throws {
          let previousRecordType = previousRecordTypeByTableName[tableName]
          let changedColumns = currentRecordType.tableInfo.subtracting(
            previousRecordType?.tableInfo ?? []
          )
          .map(\.name)
          // NB: Records deleted locally, whose deletions are still waiting for confirmation, must not
          //     be written back.
          let lastKnownServerRecords = try await metadatabase.read { db in
            try SyncMetadata
              .where { $0.recordType.eq(tableName) && !$0._isDeleted }
              .select(\._lastKnownServerRecordAllFields)
              .fetchAll(db)
          }
          var refreshedRecords: [CKRecord.ID: CKRecord] = [:]
          let recordIDsByDatabaseScope = Dictionary(
            grouping: lastKnownServerRecords.compactMap { record -> CKRecord.ID? in
              guard
                let record,
                changedColumns.contains(where: {
                  $0 != T.primaryKey.name && record.hasSet(key: $0) && record[$0] is CKAsset
                })
              else { return nil }
              return record.recordID
            },
            by: {
              $0.zoneID.ownerName == CKCurrentUserDefaultName ? CKDatabase.Scope.private : .shared
            }
          )
          for (scope, recordIDs) in recordIDsByDatabaseScope {
            try await container.database(for: scope).records(for: recordIDs) { results in
              for (recordID, result) in results {
                refreshedRecords[recordID] = try result.get()
              }
            }
          }
          for case .some(let lastKnownServerRecord) in lastKnownServerRecords {
            let query = updateQuery(
              for: table,
              record: refreshedRecords[lastKnownServerRecord.recordID] ?? lastKnownServerRecord,
              columnNames: T.TableColumns.writableColumns.map(\.name),
              changedColumnNames: changedColumns
            )
            try await userDatabase.write { db in
              try #sql(query).execute(db)
            }
          }
        }
        try await open(table)
      }
    }

    package func tearDownSyncEngine() throws {
      try userDatabase.write { db in
        for table in tables.reversed() {
          try table.base
            .dropTriggers(defaultZone: defaultZone, privateTables: privateTables, db: db)
        }
        for trigger in SyncMetadata.callbackTriggers(for: self).reversed() {
          try trigger.drop().execute(db)
        }
      }
      try metadatabase.erase()
      try migrate(metadatabase: metadatabase)
    }

    /// Deletes synchronized data locally on device and restarts the sync engine.
    ///
    /// This method is called automatically by the sync engine when it detects the device's iCloud
    /// account has logged out or changed. To customize this behavior, provide a
    /// ``SyncEngineDelegate`` to the sync engine and implement
    /// ``SyncEngineDelegate/syncEngine(_:accountChanged:)``.
    ///
    /// > Important: It is only appropriate to call this method when the device's iCloud account
    /// > logs out or changes.
    public func deleteLocalData() async throws {
      stop()
      try tearDownSyncEngine()
      await withErrorReporting(.sqliteDataCloudKitFailure) {
        try await userDatabase.write { db in
          for table in tables {
            func open<T>(_: some SynchronizableTable<T>) {
              withErrorReporting(.sqliteDataCloudKitFailure) {
                try T.delete().execute(db)
              }
            }
            open(table)
          }
          try setUpSyncEngine(writableDB: db)
        }
      }
      try await start()
    }

    @DatabaseFunction(
      "sqlitedata_icloud_didUpdate",
      as: ((
        String,
        String,
        String,
        String,
        String,
        [String]?.JSONRepresentation
      ) -> Void).self
    )
    func didUpdate(
      recordName: String,
      zoneName: String,
      ownerName: String,
      oldZoneName: String,
      oldOwnerName: String,
      descendantRecordNames: [String]?
    ) {
      var oldChanges: [CKSyncEngine.PendingRecordZoneChange] = []
      var newChanges: [CKSyncEngine.PendingRecordZoneChange] = []

      let oldZoneID = CKRecordZone.ID(zoneName: oldZoneName, ownerName: oldOwnerName)
      let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)

      if oldZoneID != zoneID {
        oldChanges.append(.deleteRecord(CKRecord.ID(recordName: recordName, zoneID: oldZoneID)))
        for descendantRecordName in descendantRecordNames ?? [] {
          oldChanges.append(
            .deleteRecord(CKRecord.ID(recordName: descendantRecordName, zoneID: oldZoneID))
          )
        }
        newChanges.append(.saveRecord(CKRecord.ID(recordName: recordName, zoneID: zoneID)))
        for descendantRecordName in descendantRecordNames ?? [] {
          newChanges.append(
            .saveRecord(CKRecord.ID(recordName: descendantRecordName, zoneID: zoneID))
          )
        }
      } else {
        newChanges.append(
          .saveRecord(CKRecord.ID(recordName: recordName, zoneID: zoneID))
        )
      }

      guard !queueWithRunningEngines(oldChanges + newChanges)
      else { return }
      noteForNextStart(oldChanges + newChanges)
    }

    @DatabaseFunction(
      "sqlitedata_icloud_didDelete",
      as: ((String, CKRecord?.SystemFieldsRepresentation, CKShare?.SystemFieldsRepresentation)
        -> Void).self
    )
    func didDelete(recordName: String, record: CKRecord?, share: CKShare?) {
      let zoneID = record?.recordID.zoneID ?? defaultZone.zoneID
      var changes: [CKSyncEngine.PendingRecordZoneChange] = [
        .deleteRecord(
          CKRecord.ID(
            recordName: recordName,
            zoneID: zoneID
          )
        )
      ]
      if let share {
        changes.append(.deleteRecord(share.recordID))
      }
      guard !queueWithRunningEngines(changes)
      else { return }
      noteForNextStart(changes)
    }

    package func acceptShare(metadata: ShareMetadata) async throws {
      guard let rootRecordID = metadata.hierarchicalRootRecordID
      else {
        reportIssue("Attempting to share without root record information.")
        return
      }
      let container = type(of: container).createContainer(identifier: metadata.containerIdentifier)
      _ = try await container.accept(metadata)
      await engineCreation()
      try await syncEngines.shared?.fetchChanges(
        CKSyncEngine.FetchChangesOptions(
          scope: .zoneIDs([rootRecordID.zoneID]),
          operationGroup: nil
        )
      )
    }

    /// Whether or not the ``SyncEngine`` is currently writing changes to the database.
    ///
    /// See <doc:CloudKitSync#Updating-triggers-to-be-compatible-with-synchronization> for more info.
    @DatabaseFunction("sqlitedata_icloud_syncEngineIsSynchronizingChanges")
    public static var isSynchronizing: Bool {
      if _isCreatingTemporaryTrigger {
        reportIssue(
          """
          Invoked 'SyncEngine.isSynchronizing' at trigger creation, which is unexpected. Use \
          'SyncEngine.$isSynchronizing' to invoke at trigger execution, instead.
          """
        )
      }
      return _isSynchronizingChanges
    }

    @available(*, deprecated, message: "Use 'SyncEngine.$isSynchronizing', instead.")
    public static func isSynchronizingChanges() -> some QueryExpression<Bool> {
      $isSynchronizing
    }

    private var sendingChangesCount: Int {
      get {
        observationRegistrar.access(self, keyPath: \.isSendingChanges)
        return activityCounts.withValue(\.sendingChangesCount)
      }
      set {
        observationRegistrar.withMutation(of: self, keyPath: \.isSendingChanges) {
          activityCounts.withValue { $0.sendingChangesCount = newValue }
        }
      }
    }
    private var fetchingChangesCount: Int {
      get {
        observationRegistrar.access(self, keyPath: \.isFetchingChanges)
        return activityCounts.withValue(\.fetchingChangesCount)
      }
      set {
        observationRegistrar.withMutation(of: self, keyPath: \.isFetchingChanges) {
          activityCounts.withValue { $0.fetchingChangesCount = newValue }
        }
      }
    }
  }

  extension PrimaryKeyedTable {
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    fileprivate static func createTriggers(
      foreignKeysByTableName: [String: [ForeignKey]],
      tablesByName: [String: any SynchronizableTable],
      defaultZone: CKRecordZone,
      privateTables: [any SynchronizableTable],
      db: Database
    ) throws {
      let parentForeignKey =
        foreignKeysByTableName[tableName]?.count == 1
        ? foreignKeysByTableName[tableName]?.first
        : nil

      for trigger in metadataTriggers(
        parentForeignKey: parentForeignKey,
        defaultZone: defaultZone,
        privateTables: privateTables
      ) {
        try trigger.execute(db)
      }
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    fileprivate static func dropTriggers(
      defaultZone: CKRecordZone,
      privateTables: [any SynchronizableTable],
      db: Database
    ) throws {
      for trigger in metadataTriggers(
        parentForeignKey: nil,
        defaultZone: defaultZone,
        privateTables: privateTables
      )
      .reversed() {
        try trigger.drop().execute(db)
      }
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngine: CKSyncEngineDelegate {
    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
      guard let event = Event(event)
      else {
        reportIssue("Unrecognized event received: \(event)")
        return
      }
      await handleEvent(event, syncEngine: syncEngine)
    }

    package func handleEvent(_ event: Event, syncEngine: any SyncEngineProtocol) async {
      #if DEBUG
        logger.log(event, syncEngine: syncEngine)
      #endif

      switch event {
      case .accountChange(let changeType):
        await handleAccountChange(changeType: changeType, syncEngine: syncEngine)
      case .stateUpdate(let stateSerialization):
        await handleStateUpdate(stateSerialization: stateSerialization, syncEngine: syncEngine)
      case .fetchedDatabaseChanges(let modifications, let deletions):
        await handleFetchedDatabaseChanges(
          modifications: modifications,
          deletions: deletions,
          syncEngine: syncEngine
        )
      case .sentDatabaseChanges:
        break
      case .fetchedRecordZoneChanges(let modifications, let deletions):
        await handleFetchedRecordZoneChanges(
          modifications: modifications,
          deletions: deletions,
          syncEngine: syncEngine
        )
      case .sentRecordZoneChanges(
        let savedRecords,
        let failedRecordSaves,
        let deletedRecordIDs,
        let failedRecordDeletes
      ):
        await handleSentRecordZoneChanges(
          savedRecords: savedRecords,
          failedRecordSaves: failedRecordSaves,
          deletedRecordIDs: deletedRecordIDs,
          failedRecordDeletes: failedRecordDeletes,
          syncEngine: syncEngine
        )

      case .willFetchRecordZoneChanges:
        await MainActor.run {
          fetchingChangesCount += 1
        }
      case .didFetchRecordZoneChanges:
        await MainActor.run {
          fetchingChangesCount -= 1
        }

      case .willFetchChanges:
        await MainActor.run {
          fetchingChangesCount += 1
        }
      case .didFetchChanges:
        await MainActor.run {
          fetchingChangesCount -= 1
        }

      case .willSendChanges:
        await MainActor.run {
          sendingChangesCount += 1
        }
      case .didSendChanges:
        await MainActor.run {
          sendingChangesCount -= 1
        }

      @unknown default:
        break
      }
    }

    public func nextRecordZoneChangeBatch(
      _ context: CKSyncEngine.SendChangesContext,
      syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
      await nextRecordZoneChangeBatch(
        reason: context.reason,
        options: context.options,
        syncEngine: syncEngine
      )
    }

    package func nextRecordZoneChangeBatch(
      reason: CKSyncEngine.SyncReason = .scheduled,
      options: CKSyncEngine.SendChangesOptions = CKSyncEngine.SendChangesOptions(scope: .all),
      syncEngine: any SyncEngineProtocol
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
      var changes = await pendingRecordZoneChanges(options: options, syncEngine: syncEngine)
      guard !changes.isEmpty
      else { return nil }
      changes.sort { lhs, rhs in
        switch (lhs, rhs) {
        case (.saveRecord(let lhs), .saveRecord(let rhs)):
          return topologicallyAscending(
            lhsTableName: lhs.tableName,
            rhsTableName: rhs.tableName,
            rootFirst: true
          )
        case (.deleteRecord(let lhs), .deleteRecord(let rhs)):
          return topologicallyAscending(
            lhsTableName: lhs.tableName,
            rhsTableName: rhs.tableName,
            rootFirst: false
          )
        case (.saveRecord, .deleteRecord):
          return false
        case (.deleteRecord, .saveRecord):
          return true
        default:
          return false
        }
      }

      #if DEBUG
        let state = LockIsolated(NextRecordZoneChangeBatchLoggingState())
        defer {
          let state = state.withValue(\.self)
          if let tabularDescription = state.tabularDescription {
            logger.debug(
              """
              SQLiteData (\(syncEngine.database.databaseScope.label).db) \
              nextRecordZoneChangeBatch: \(reason)
                \(tabularDescription)
              """
            )
          }
        }
      #endif

      let batch = await syncEngine.recordZoneChangeBatch(pendingChanges: changes) { recordID in
        guard
          let (metadata, allFields) = await withErrorReporting(
            .sqliteDataCloudKitFailure,
            catching: {
              try await metadatabase.read { db in
                try SyncMetadata
                  .find(recordID)
                  .select { ($0, $0._lastKnownServerRecordAllFields) }
                  .fetchOne(db)
              }
            }
          )
            ?? nil
        else {
          syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
          return nil
        }

        var missingTable: CKRecord.ID?
        var missingRecord: CKRecord.ID?
        var sentRecord: CKRecord.ID?
        #if DEBUG
          defer {
            state.withValue { [missingTable, missingRecord, sentRecord] in
              if let missingTable {
                $0.events.append("⚠️ Missing table")
                $0.recordTypes.append(metadata.recordType)
                $0.recordNames.append(missingTable.recordName)
              }
              if let missingRecord {
                $0.events.append("⚠️ Missing record")
                $0.recordTypes.append(metadata.recordType)
                $0.recordNames.append(missingRecord.recordName)
              }
              if let sentRecord {
                $0.events.append("➡️ Sending")
                $0.recordTypes.append(metadata.recordType)
                $0.recordNames.append(sentRecord.recordName)
              }
            }
          }
        #endif

        guard let table = tablesByName[metadata.recordType]
        else {
          syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
          missingTable = recordID
          return nil
        }
        func open<T>(_: some SynchronizableTable<T>) async -> CKRecord? {
          let row =
            await withErrorReporting(.sqliteDataCloudKitFailure) {
              // NB: Fake 'sending' result.
              nonisolated(unsafe) var result: T.QueryOutput?
              try await userDatabase.read { db in
                result =
                  try T
                  .unscoped
                  .where {
                    #sql("\($0.primaryKey) = \(bind: metadata.recordPrimaryKey)")
                  }
                  .fetchOne(db)
              }
              return result
            }
            ?? nil
          guard let row
          else {
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            missingRecord = recordID
            return nil
          }

          let record =
            allFields
            ?? CKRecord(
              recordType: metadata.recordType,
              recordID: recordID
            )
          if let parentRecordName = metadata.parentRecordName,
            !privateTables.contains(where: { $0.base.tableName == metadata.recordType })
          {
            record.parent = CKRecord.Reference(
              recordID: CKRecord.ID(
                recordName: parentRecordName,
                zoneID: recordID.zoneID
              ),
              action: .none
            )
          } else {
            record.parent = nil
          }

          record.update(
            with: T(queryOutput: row),
            userModificationTime: metadata.userModificationTime
          )
          await refreshLastKnownServerRecord(record)
          sentRecord = recordID
          return record
        }
        return await open(table)
      }
      return batch
    }

    private func pendingRecordZoneChanges(
      options: CKSyncEngine.SendChangesOptions,
      syncEngine: any SyncEngineProtocol
    ) async -> [CKSyncEngine.PendingRecordZoneChange] {
      await withErrorReporting(.sqliteDataCloudKitFailure) {
        try await enqueueLocallyPendingChanges(scope: syncEngine.database.databaseScope)
      }
      var changes = syncEngine.state.pendingRecordZoneChanges.filter(options.scope.contains)
      guard !changes.isEmpty
      else { return [] }

      // NB: A record whose row is on this device is never deleted on the server, and neither is
      //     the share of a root whose row is: every other device would then delete the row and
      //     everything under it.
      //     Such a deletion comes from a queue older than the row's return (the saved state of an
      //     older version, restored before 'settleReturnedRows' runs), so it leaves the queue
      //     unsent; that start deletes the row and queues the deletion again.
      let keptRecordIDs = await recordIDsOfRowsOnDevice(
        among: changes.compactMap { change -> CKRecord.ID? in
          guard case .deleteRecord(let recordID) = change
          else { return nil }
          return recordID
        }
      )
      if !keptRecordIDs.isEmpty {
        changes.removeAll { change in
          guard case .deleteRecord(let recordID) = change
          else { return false }
          return keptRecordIDs.contains(recordID)
        }
        syncEngine.state.remove(
          pendingRecordZoneChanges: keptRecordIDs.map { .deleteRecord($0) }
        )
        guard !changes.isEmpty
        else { return [] }
      }

      let deletedRecordIDs: [CKRecord.ID] = changes.compactMap {
        switch $0 {
        case .saveRecord(_):
          return nil
        case .deleteRecord(let recordID):
          return recordID
        @unknown default:
          return nil
        }
      }
      var droppedDeletionRecordIDs: [CKRecord.ID] = []

      if syncEngine.database.databaseScope == .shared {
        let (sharesToDelete, recordsWithRoot):
          ([CKShare?], [(lastKnownServerRecord: CKRecord?, rootLastKnownServerRecord: CKRecord?)]) =
            await withErrorReporting(.sqliteDataCloudKitFailure) {
              guard !deletedRecordIDs.isEmpty
              else { return ([], []) }

              return try await metadatabase.read { db in
                let sharesToDelete =
                  try SyncMetadata
                  .findAll(deletedRecordIDs)
                  .where(\.isShared)
                  .select(\.share)
                  .fetchAll(db)

                let recordsWithRoot =
                  try With {
                    SyncMetadata
                      .findAll(deletedRecordIDs)
                      .where { $0.parentRecordName.is(nil) }
                      .select {
                        RecordWithRoot.Columns(
                          parentRecordName: $0.parentRecordName,
                          recordName: $0.recordName,
                          lastKnownServerRecord: $0.lastKnownServerRecord,
                          rootRecordName: $0.recordName,
                          rootLastKnownServerRecord: $0.lastKnownServerRecord
                        )
                      }
                      .union(
                        all: true,
                        SyncMetadata
                          .join(RecordWithRoot.all) { $1.recordName.is($0.parentRecordName) }
                          .select { metadata, tree in
                            RecordWithRoot.Columns(
                              parentRecordName: metadata.parentRecordName,
                              recordName: metadata.recordName,
                              lastKnownServerRecord: metadata.lastKnownServerRecord,
                              rootRecordName: tree.rootRecordName,
                              rootLastKnownServerRecord: tree.rootLastKnownServerRecord
                            )
                          }
                      )
                  } query: {
                    RecordWithRoot
                      .select { ($0.lastKnownServerRecord, $0.rootLastKnownServerRecord) }
                  }
                  .fetchAll(db)

                return (sharesToDelete, recordsWithRoot)
              }
            }
            ?? ([], [])

        let shareRecordIDsToDelete = sharesToDelete.compactMap(\.?.recordID)

        for recordWithRoot in recordsWithRoot {
          guard
            let lastKnownServerRecord = recordWithRoot.lastKnownServerRecord,
            let rootLastKnownServerRecord = recordWithRoot.rootLastKnownServerRecord
          else { continue }
          guard let rootShareRecordID = rootLastKnownServerRecord.share?.recordID
          else { continue }
          guard shareRecordIDsToDelete.contains(rootShareRecordID)
          else { continue }
          changes.removeAll(where: { $0 == .deleteRecord(lastKnownServerRecord.recordID) })
          syncEngine.state.remove(
            pendingRecordZoneChanges: [.deleteRecord(lastKnownServerRecord.recordID)]
          )
          droppedDeletionRecordIDs.append(lastKnownServerRecord.recordID)
        }
      }

      // NB: The metadata of a deletion in this batch stays until the deletion leaves the queue (see
      //     'handleSentRecordZoneChanges'): the batch may not reach the server (CloudKit throttles
      //     it, the network drops, the app is closed), and a fetch in the meantime must still see
      //     that the record is deleted locally. Deletions dropped above are never sent, because
      //     deleting their share deletes them, so their metadata goes now.
      await withErrorReporting(.sqliteDataCloudKitFailure) { [droppedDeletionRecordIDs] in
        guard !droppedDeletionRecordIDs.isEmpty
        else { return }
        try await userDatabase.write { db in
          try removeDeletionMetadata(for: droppedDeletionRecordIDs, db: db)
        }
      }

      return changes
    }

    package func handleAccountChange(
      changeType: CKSyncEngine.Event.AccountChange.ChangeType,
      syncEngine: any SyncEngineProtocol
    ) async {
      // NB: An engine can report the account as soon as it is created, before it is in place.
      await engineCreation()
      guard syncEngine === syncEngines.private
      else { return }

      switch changeType {
      case .signIn:
        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(defaultZone)])
        await withErrorReporting {
          try await enqueueUnknownRecordsForCloudKit()
        }
        await delegate?.syncEngine(self, accountChanged: changeType)
      case .signOut, .switchAccounts:
        guard let delegate
        else {
          await withErrorReporting(.sqliteDataCloudKitFailure) {
            try await deleteLocalData()
          }
          return
        }
        await delegate.syncEngine(self, accountChanged: changeType)

      @unknown default:
        break
      }
    }

    package func handleStateUpdate(
      stateSerialization: CKSyncEngine.State.Serialization,
      syncEngine: any SyncEngineProtocol
    ) async {
      await withErrorReporting(.sqliteDataCloudKitFailure) {
        try await userDatabase.write { db in
          try StateSerialization.upsert {
            StateSerialization.Draft(
              scope: syncEngine.database.databaseScope,
              data: stateSerialization
            )
          }
          .execute(db)
        }
      }
    }

    package func handleFetchedDatabaseChanges(
      modifications: [CKRecordZone.ID],
      deletions: [(zoneID: CKRecordZone.ID, reason: CKDatabase.DatabaseChange.Deletion.Reason)],
      syncEngine: any SyncEngineProtocol
    ) async {
      let defaultZoneDeleted =
        await withErrorReporting(.sqliteDataCloudKitFailure) {
          try await userDatabase.write { db in
            var defaultZoneDeleted = false
            for (zoneID, reason) in deletions {
              switch reason {
              case .deleted, .purged:
                try deleteRecords(in: zoneID, db: db)
                if zoneID == self.defaultZone.zoneID {
                  defaultZoneDeleted = true
                }
              case .encryptedDataReset:
                try uploadRecords(in: zoneID, db: db)
              @unknown default:
                reportIssue("Unknown deletion reason: \(reason)")
              }
            }
            return defaultZoneDeleted
          }
        }
        ?? false
      if defaultZoneDeleted {
        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(self.defaultZone)])
      }
      @Sendable
      func deleteRecords(in zoneID: CKRecordZone.ID, db: Database) throws {
        let recordTypes = Dictionary(
          grouping:
            try SyncMetadata
            .where { $0.zoneName.eq(zoneID.zoneName) && $0.ownerName.eq(zoneID.ownerName) }
            .select { ($0.recordType, $0.recordPrimaryKey) }
            .fetchAll(db),
          by: \.0
        )
        .mapValues {
          $0.map(\.1)
        }
        for (recordType, primaryKeys) in recordTypes {
          guard let table = tablesByName[recordType]
          else { continue }
          func open<T: PrimaryKeyedTable>(_: some SynchronizableTable<T>) {
            withErrorReporting(.sqliteDataCloudKitFailure) {
              try T.unscoped.where { #sql("\($0.primaryKey)").in(primaryKeys) }.delete().execute(db)
            }
          }
          open(table)
        }
        // NB: Rows deleted locally are already gone, but their deletions may still be waiting for
        //     confirmation. The zone is gone, so their metadata can go too.
        try SyncMetadata
          .where {
            $0.zoneName.eq(zoneID.zoneName) && $0.ownerName.eq(zoneID.ownerName) && $0._isDeleted
          }
          .delete()
          .execute(db)
      }
      @Sendable
      func uploadRecords(in zoneID: CKRecordZone.ID, db: Database) throws {
        let recordTypes = Set(
          try SyncMetadata
            .where(\.hasLastKnownServerRecord)
            .select(\.lastKnownServerRecord)
            .fetchAll(db)
            .compactMap { $0?.recordID.zoneID == zoneID ? $0?.recordType : nil }
        )
        var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] = []
        for recordType in recordTypes {
          guard let table = tablesByName[recordType]
          else { continue }
          func open<T>(_: some SynchronizableTable<T>) {
            withErrorReporting(.sqliteDataCloudKitFailure) {
              pendingRecordZoneChanges.append(
                contentsOf: try T.unscoped.select(\._recordName).fetchAll(db).map {
                  .saveRecord(CKRecord.ID(recordName: $0, zoneID: zoneID))
                }
              )
            }
          }
          open(table)
        }
        syncEngine.state.add(pendingRecordZoneChanges: pendingRecordZoneChanges)
      }
    }

    package func handleFetchedRecordZoneChanges(
      modifications: [CKRecord] = [],
      deletions: [(recordID: CKRecord.ID, recordType: CKRecord.RecordType)] = [],
      syncEngine: any SyncEngineProtocol
    ) async {
      let deletedRecordIDsByRecordType = OrderedDictionary(
        grouping: deletions.sorted { lhs, rhs in
          topologicallyAscending(
            lhsTableName: lhs.recordType,
            rhsTableName: rhs.recordType,
            rootFirst: false
          )
        },
        by: \.recordType
      )
      .mapValues { OrderedSet($0.map(\.recordID)) }
      // NB: The records this fetch deletes are settled by it, not by 'settleDependents'. The ones
      //     it changes are not: a fetch also delivers this device's own earlier saves, and a record
      //     that still points at a deleted one can't be written, and would wait for good.
      let fetchedRecordNames = Set(deletions.map(\.recordID.recordName))
      var dependents: [Dependent] = []
      for (recordType, recordIDs) in deletedRecordIDsByRecordType {
        if let table = tablesByName[recordType] {
          func open<T>(_: some SynchronizableTable<T>) async -> [Dependent] {
            await withErrorReporting(.sqliteDataCloudKitFailure) {
              try await userDatabase.write { db in
                let primaryKeys =
                  try SyncMetadata
                  .findAll(recordIDs)
                  .select(\.recordPrimaryKey)
                  .fetchAll(db)
                let dependentRows = try self.dependentRows(
                  of: [T.tableName: Set(primaryKeys)],
                  db: db
                )
                let dependentRecordNames = dependentRows.recordNames.filter {
                  !fetchedRecordNames.contains($0)
                }
                let deletedDependentRecordNames = dependentRows.deletedRecordNames
                let dependents =
                  try SyncMetadata
                  .where {
                    $0.recordName.in(dependentRecordNames)
                      && $0.hasLastKnownServerRecord
                      && !$0._isDeleted
                  }
                  .fetchAll(db)
                  .map {
                    Dependent(
                      metadata: $0,
                      isDeleted: deletedDependentRecordNames.contains($0.recordName)
                    )
                  }

                try T
                  .unscoped
                  .where {
                    #sql("\($0.primaryKey)").in(
                      SyncMetadata.findAll(recordIDs)
                        .select(\.recordPrimaryKey)
                    )
                  }
                  .delete()
                  .execute(db)

                try UnsyncedRecordID
                  .findAll(recordIDs)
                  .delete()
                  .execute(db)

                // NB: The record was deleted locally too, and its deletion is still waiting for
                //     confirmation. The server deleted it, so its metadata can go now.
                try SyncMetadata
                  .where { $0.recordName.in(recordIDs.map(\.recordName)) && $0._isDeleted }
                  .delete()
                  .execute(db)
                return dependents
              }
            }
              ?? []
          }
          dependents += await open(table)
        } else if recordType == CKRecord.SystemType.share {
          await withErrorReporting(.sqliteDataCloudKitFailure) {
            try await deleteShares(shareRecordIDs: recordIDs)
          }
        } else {
          // NB: Deleting a record from a table we do not currently recognize.
          await withErrorReporting(.sqliteDataCloudKitFailure) {
            try await userDatabase.write { db in
              try SyncMetadata
                .findAll(recordIDs)
                .delete()
                .execute(db)
            }
          }
        }
      }

      struct RecordAndAssets {
        let record: CKRecord
        let assets: [String: Data]
      }

      let modificationRecordIDs = Set(modifications.map(\.recordID))
      var (cachedUnsyncedRecords, unsyncedRecordIDs): ([RecordAndAssets], Set<CKRecord.ID>) =
        await withErrorReporting(.sqliteDataCloudKitFailure) {
          try await userDatabase.write { db in
            var unsyncedRecordIDsToDelete: Set<CKRecord.ID> = []
            var cachedUnsyncedRecords: [RecordAndAssets] = []
            var unsyncedRecordIDs: Set<CKRecord.ID> = []
            for unsyncedRecordID in try UnsyncedRecordID.all.fetchAll(db) {
              let recordID = CKRecord.ID(unsyncedRecordID: unsyncedRecordID)
              if modificationRecordIDs.contains(recordID) {
                unsyncedRecordIDsToDelete.insert(recordID)
              } else if let record = unsyncedRecordID.record?.copy() as? CKRecord {
                cachedUnsyncedRecords
                  .append(
                    RecordAndAssets(
                      record: record,
                      assets: unsyncedRecordID.assets
                    )
                  )
              } else {
                unsyncedRecordIDs.insert(recordID)
              }
            }
            if !unsyncedRecordIDsToDelete.isEmpty {
              try UnsyncedRecordID
                .findAll(unsyncedRecordIDsToDelete)
                .delete()
                .execute(db)
            }
            return (cachedUnsyncedRecords, unsyncedRecordIDs)
          }
        }
        ?? ([], [])

      var unsyncedRecords: [CKRecord] = []
      for recordAndAssets in cachedUnsyncedRecords {
        let (record, assets) = (recordAndAssets.record, recordAndAssets.assets)
        do {
          for (key, data) in assets {
            let url = URL.temporaryDirectory.appendingPathComponent(uuid.wrappedValue().uuidString)
            try dataManager.wrappedValue.save(data, to: url)
            record[key] = CKAsset.init(fileURL: url)
          }
          unsyncedRecords.append(record)
        } catch {
          unsyncedRecordIDs.insert(record.recordID)
        }
      }
      await withErrorReporting(.sqliteDataCloudKitFailure) {
        let orderedUnsyncedRecordIDs = unsyncedRecordIDs.sorted {
          topologicallyAscending(
            lhsTableName: $0.tableName,
            rhsTableName: $1.tableName,
            rootFirst: true
          )
        }
        try await syncEngine.database.records(for: orderedUnsyncedRecordIDs) { results in
          for (recordID, result) in results {
            switch result {
            case .success(let record):
              unsyncedRecords.append(record)
            case .failure(let error as CKError) where error.code == .unknownItem:
              try await userDatabase.write { db in
                try UnsyncedRecordID.find(recordID).delete().execute(db)
              }
            case .failure:
              continue
            }
          }
        }
      }

      let modifications = (modifications + unsyncedRecords).sorted { lhs, rhs in
        topologicallyAscending(
          lhsTableName: lhs.recordType,
          rhsTableName: rhs.recordType,
          rootFirst: true
        )
      }

      let (fetchedShares, shareRecordIDs): ([CKShare], Set<CKRecord.ID>) =
        await withErrorReporting(.sqliteDataCloudKitFailure) {
          try await userDatabase.write { db in
            var fetchedShares: [CKShare] = []
            var shareRecordIDs: Set<CKRecord.ID> = []
            for record in modifications {
              if let share = record as? CKShare {
                fetchedShares.append(share)
              } else {
                upsertFromServerRecord(record, db: db)
                if let shareReference = record.share {
                  shareRecordIDs.insert(shareReference.recordID)
                }
              }
            }
            shareRecordIDs.subtract(fetchedShares.map(\.recordID))
            return (fetchedShares, shareRecordIDs)
          }
        }
        ?? ([], [])

      var shares = fetchedShares
      try? await syncEngine.database.records(for: Array(shareRecordIDs)) { results in
        for result in results.values {
          guard let share = try? result.get() as? CKShare
          else { continue }
          shares.append(share)
        }
      }

      await withTaskGroup(of: Void.self) { group in
        for share in shares {
          group.addTask {
            await withErrorReporting(.sqliteDataCloudKitFailure) {
              try await self.cacheShare(share)
            }
          }
        }
      }

      await settleDependents(
        dependents,
        deletedRecordNames: Set(deletions.map(\.recordID.recordName)),
        syncEngine: syncEngine
      )
    }

    /// Settles the records whose rows a fetched deletion took along on this device.
    ///
    /// Another device deleted a record, and SQLite deleted the rows under it here too, or cleared
    /// their reference to it. That device sent the deletions of what it had under the record, but
    /// not of what other devices added there since, which would stay on the server pointing at
    /// nothing: every device that fetches it then waits for its parent for good. So each of
    /// these records is checked against iCloud:
    ///
    /// * Still under a deleted record: it is deleted in iCloud too, or, when only its reference
    ///   was cleared, uploaded without it, as the device that made the deletion does. A deletion
    ///   wins over what other devices did under the record.
    /// * Under another record by now (another device moved it): it is written back from the
    ///   server.
    /// * Gone from the server: nothing more.
    /// * When iCloud can't be reached, a deleted one is fetched again with the next fetch, as a
    ///   record waiting for its parent is.
    private func settleDependents(
      _ dependents: [Dependent],
      deletedRecordNames: Set<String>,
      syncEngine: any SyncEngineProtocol
    ) async {
      guard !dependents.isEmpty
      else { return }
      let recordIDs = dependents.map(\.metadata.zonedRecordID)
      var results: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
      do {
        try await syncEngine.database.records(for: recordIDs) { batchResults in
          results.merge(batchResults, uniquingKeysWith: { _, result in result })
        }
      } catch {
        // NB: Fetched again with the next fetch, as records waiting for a parent are: one that
        //     moved comes back then, and one still under a deleted record keeps waiting.
        await withErrorReporting(.sqliteDataCloudKitFailure) {
          try await userDatabase.write { db in
            try UnsyncedRecordID
              .insert {
                dependents.filter(\.isDeleted).map {
                  UnsyncedRecordID(recordID: $0.metadata.zonedRecordID)
                }
              }
              onConflictDoUpdate: { _ in }
              .execute(db)
          }
        }
        return
      }
      var serverRecordsByName: [String: CKRecord] = [:]
      for dependent in dependents {
        guard case .success(let record) = results[dependent.metadata.zonedRecordID]
        else { continue }
        serverRecordsByName[dependent.metadata.recordName] = record
      }

      // NB: A record under a record that is written back is no longer under a deleted one.
      var goneRecordNames = deletedRecordNames.union(
        dependents.filter(\.isDeleted).map(\.metadata.recordName)
      )
      var movedRecordNames: Set<String> = []
      while true {
        let newlyMovedRecordNames = serverRecordsByName.compactMap { recordName, record in
          !movedRecordNames.contains(recordName)
            && parentRecordNames(of: record).isDisjoint(with: goneRecordNames)
            ? recordName
            : nil
        }
        guard !newlyMovedRecordNames.isEmpty
        else { break }
        movedRecordNames.formUnion(newlyMovedRecordNames)
        goneRecordNames.subtract(newlyMovedRecordNames)
      }

      var deletedRecords: [CKRecord] = []
      var clearedRecordIDs: [CKRecord.ID] = []
      for dependent in dependents {
        let recordName = dependent.metadata.recordName
        guard
          let record = serverRecordsByName[recordName],
          !movedRecordNames.contains(recordName)
        else { continue }
        if dependent.isDeleted {
          deletedRecords.append(record)
        } else {
          clearedRecordIDs.append(record.recordID)
        }
      }
      await withErrorReporting(.sqliteDataCloudKitFailure) {
        try await deleteRecordsNotOnDevice(deletedRecords)
      }
      if !clearedRecordIDs.isEmpty {
        await withErrorReporting(.sqliteDataCloudKitFailure) {
          try await userDatabase.write { [clearedRecordIDs] db in
            try SyncMetadata
              .findAll(clearedRecordIDs)
              .update { $0.userModificationTime = $currentTime() }
              .execute(db)
            try UnsyncedRecordID.findAll(clearedRecordIDs).delete().execute(db)
            if !queueWithRunningEngines(clearedRecordIDs.map { .saveRecord($0) }) {
              noteForNextStart(clearedRecordIDs.map { .saveRecord($0) })
            }
          }
        }
      }

      let movedRecords = serverRecordsByName
        .filter { movedRecordNames.contains($0.key) }
        .values
        .sorted {
          topologicallyAscending(
            lhsTableName: $0.recordType,
            rhsTableName: $1.recordType,
            rootFirst: true
          )
        }
      for record in movedRecords {
        await upsertFromServerRecord(record)
      }
    }

    private func topologicallyAscending(
      lhsTableName: String?,
      rhsTableName: String?,
      rootFirst: Bool
    ) -> Bool {
      switch (lhsTableName, rhsTableName) {
      case (nil, nil), (nil, _):
        return false
      case (_, nil):
        return true
      case (.some(let lhs), .some(let rhs)):
        let lhsIndex = tablesByOrder[lhs] ?? (rootFirst ? .max : .min)
        let rhsIndex = tablesByOrder[rhs] ?? (rootFirst ? .max : .min)
        guard lhsIndex != rhsIndex
        else {
          return lhs < rhs
        }
        return rootFirst ? lhsIndex < rhsIndex : lhsIndex > rhsIndex
      }
    }

    package func handleSentRecordZoneChanges(
      savedRecords: [CKRecord] = [],
      failedRecordSaves: [(record: CKRecord, error: CKError)] = [],
      deletedRecordIDs: [CKRecord.ID] = [],
      failedRecordDeletes: [CKRecord.ID: CKError] = [:],
      syncEngine: any SyncEngineProtocol
    ) async {
      for savedRecord in savedRecords {
        await refreshLastKnownServerRecord(savedRecord)
      }

      // NB: A record deleted locally after its save was sent must not be queued to be saved again:
      //     its deletion is queued, and CKSyncEngine discards a pending deletion when a save of the
      //     same record is added after it, so the deletion would never be sent.
      let pendingDeletionRecordNames: Set<String> =
        await withErrorReporting(.sqliteDataCloudKitFailure) { () async throws -> Set<String> in
          guard !failedRecordSaves.isEmpty
          else { return [] }
          let recordNames = failedRecordSaves.map(\.record.recordID.recordName)
          return try await metadatabase.read { db in
            Set(
              try SyncMetadata
                .where { $0.recordName.in(recordNames) && $0._isDeleted }
                .select(\.recordName)
                .fetchAll(db)
            )
          }
        }
        ?? []

      var newPendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] = []
      var newPendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] = []
      defer {
        syncEngine.state.add(pendingDatabaseChanges: newPendingDatabaseChanges)
        syncEngine.state.add(
          pendingRecordZoneChanges: newPendingRecordZoneChanges.filter {
            guard case .saveRecord(let recordID) = $0
            else { return true }
            return !pendingDeletionRecordNames.contains(recordID.recordName)
          }
        )
      }
      var permissionFailedRecordTypes: [CKRecord.ID: String] = [:]
      for (failedRecord, error) in failedRecordSaves {
        func clearServerRecord() async {
          await withErrorReporting(.sqliteDataCloudKitFailure) {
            try await userDatabase.write { db in
              try SyncMetadata
                .find(failedRecord.recordID)
                .update { $0.setLastKnownServerRecord(nil) }
                .execute(db)
            }
          }
        }

        switch error.code {
        case .serverRecordChanged:
          guard let serverRecord = error.serverRecord else { continue }
          await upsertFromServerRecord(serverRecord)
          newPendingRecordZoneChanges.append(.saveRecord(failedRecord.recordID))

        case .zoneNotFound:
          let zone = CKRecordZone(zoneID: failedRecord.recordID.zoneID)
          newPendingDatabaseChanges.append(.saveZone(zone))
          newPendingRecordZoneChanges.append(.saveRecord(failedRecord.recordID))
          await clearServerRecord()

        case .unknownItem:
          newPendingRecordZoneChanges.append(.saveRecord(failedRecord.recordID))
          await clearServerRecord()

        case .serverRejectedRequest:
          await clearServerRecord()

        case .referenceViolation:
          // NB: The server does not have this record's parent. That only means the parent was
          //     deleted if the server ever confirmed it. A parent the server never confirmed is
          //     still on its way (an earlier batch that hasn't landed, a concurrent send, or a
          //     save that was dropped), so applying the 'ON DELETE' action here would destroy the
          //     child and every record that cascades from it. Queue both again instead: parents
          //     sort before their children, so the parent is sent first.
          if let parentRecordID = failedRecord.parent?.recordID,
            await isAwaitingFirstUpload(parentRecordID)
          {
            newPendingRecordZoneChanges.append(.saveRecord(parentRecordID))
            newPendingRecordZoneChanges.append(.saveRecord(failedRecord.recordID))
            continue
          }
          guard
            let recordPrimaryKey = failedRecord.recordID.recordPrimaryKey,
            let table = tablesByName[failedRecord.recordType],
            foreignKeysByTableName[table.base.tableName]?.count == 1,
            let foreignKey = foreignKeysByTableName[table.base.tableName]?.first
          else {
            continue
          }
          func open<T>(_: some SynchronizableTable<T>) async throws {
            try await userDatabase.write { db in
              try $_isSynchronizingChanges.withValue(false) {
                switch foreignKey.onDelete {
                case .cascade:
                  try T
                    .unscoped
                    .where { #sql("\($0.primaryKey) = \(bind: recordPrimaryKey)") }
                    .delete()
                    .execute(db)
                case .restrict:
                  preconditionFailure(
                    "'RESTRICT' foreign key actions not supported for parent relationships."
                  )
                case .setDefault:
                  guard
                    let recordType = try RecordType.find(T.tableName).fetchOne(db),
                    let columnInfo = recordType.tableInfo.first(where: {
                      $0.name == foreignKey.from
                    })
                  else { return }
                  let defaultValue = columnInfo.defaultValue ?? "NULL"
                  try #sql(
                    """
                    UPDATE \(T.self)
                    SET \(quote: foreignKey.from, delimiter: .identifier) = (\(raw: defaultValue))
                    WHERE (\(T.primaryKey)) = (\(bind: recordPrimaryKey))
                    """
                  )
                  .execute(db)
                  break
                case .setNull:
                  try #sql(
                    """
                    UPDATE \(T.self)
                    SET \(quote: foreignKey.from, delimiter: .identifier) = NULL
                    WHERE (\(T.primaryKey)) = (\(bind: recordPrimaryKey))
                    """
                  )
                  .execute(db)
                case .noAction:
                  preconditionFailure(
                    "'NO ACTION' foreign key actions not supported for parent relationships."
                  )
                }
              }
            }
          }
          await withErrorReporting(.sqliteDataCloudKitFailure) {
            try await open(table)
          }

        case .permissionFailure:
          guard
            failedRecord.recordID.recordPrimaryKey != nil,
            tablesByName[failedRecord.recordType] != nil
          else { continue }
          permissionFailedRecordTypes[failedRecord.recordID] = failedRecord.recordType

        case .batchRequestFailed:
          newPendingRecordZoneChanges.append(.saveRecord(failedRecord.recordID))
          break

        case .quotaExceeded:
          await withErrorReporting {
            try await userDatabase.write { db in
              try PendingRecordZoneChange.insert {
                PendingRecordZoneChange(
                  .saveRecord(failedRecord.recordID),
                  databaseScope: failedRecord.recordID.zoneID.databaseScope
                )
              }
              .execute(db)
            }
          }

        case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
          .notAuthenticated, .operationCancelled,
          .internalError, .partialFailure, .badContainer, .requestRateLimited, .missingEntitlement,
          .invalidArguments, .resultsTruncated, .assetFileNotFound,
          .assetFileModified, .incompatibleVersion, .constraintViolation, .changeTokenExpired,
          .badDatabase, .limitExceeded, .userDeletedZone, .tooManyParticipants,
          .alreadyShared, .managedAccountRestricted, .participantMayNeedVerification,
          .serverResponseLost, .assetNotAvailable, .accountTemporarilyUnavailable:
          continue
        #if canImport(FoundationModels)
          case .participantAlreadyInvited:
            continue
        #endif
        @unknown default:
          continue
        }
      }

      await withErrorReporting(.sqliteDataCloudKitFailure) {
        try await container.sharedCloudDatabase.records(
          for: Array(permissionFailedRecordTypes.keys)
        ) { results in
          for (recordID, result) in results {
            await withErrorReporting(.sqliteDataCloudKitFailure) {
              do {
                await upsertFromServerRecord(try result.get(), force: true)
              } catch let error as CKError where error.code == .unknownItem {
                guard
                  let recordPrimaryKey = recordID.recordPrimaryKey,
                  let recordType = permissionFailedRecordTypes[recordID],
                  let table = tablesByName[recordType]
                else { return }
                func open<T>(_: some SynchronizableTable<T>) async throws {
                  try await userDatabase.write { db in
                    try T
                      .unscoped
                      .where { #sql("\($0.primaryKey) = \(bind: recordPrimaryKey)") }
                      .delete()
                      .execute(db)
                  }
                }
                try await open(table)
              }
            }
          }
        }
      }

      let enqueuedUnsyncedRecordID =
        await withErrorReporting(.sqliteDataCloudKitFailure) {
          try await userDatabase.write { db in
            var enqueuedUnsyncedRecordID = false
            for (failedRecordID, error) in failedRecordDeletes {
              switch error.code {
              case .referenceViolation:
                enqueuedUnsyncedRecordID = true
                try UnsyncedRecordID.insert {
                  UnsyncedRecordID(recordID: failedRecordID)
                } onConflictDoUpdate: { _ in
                }
                .execute(db)
                syncEngine.state.remove(pendingRecordZoneChanges: [.deleteRecord(failedRecordID)])
                break
              case .batchRequestFailed:
                syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(failedRecordID)])
                break
              case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                .notAuthenticated, .operationCancelled, .internalError, .partialFailure,
                .badContainer, .requestRateLimited, .missingEntitlement, .invalidArguments,
                .resultsTruncated, .assetFileNotFound, .assetFileModified, .incompatibleVersion,
                .constraintViolation, .changeTokenExpired, .badDatabase, .quotaExceeded,
                .limitExceeded, .userDeletedZone, .tooManyParticipants, .alreadyShared,
                .managedAccountRestricted, .participantMayNeedVerification, .serverResponseLost,
                .assetNotAvailable, .accountTemporarilyUnavailable, .permissionFailure,
                .unknownItem, .serverRecordChanged, .serverRejectedRequest, .zoneNotFound:
                break
              #if canImport(FoundationModels)
                case .participantAlreadyInvited:
                  break
              #endif
              @unknown default:
                break
              }
            }

            // NB: A deletion keeps its metadata until it leaves the queue. Confirmed deletions
            //     leave it now. A failed deletion stays queued only when CloudKit retries its error
            //     (CKSyncEngine keeps those pending) or when it was queued again above; any other
            //     failure drops it, so its metadata goes as well and a later fetch of the record can
            //     bring the row back, as it did before deletions kept their metadata. A reference
            //     violation drops its metadata too, before the record is fetched again below.
            let queuedRecordZoneChanges =
              failedRecordDeletes.isEmpty
              ? []
              : Set(syncEngine.state.pendingRecordZoneChanges)
            let finishedDeletionRecordIDs =
              deletedRecordIDs
              + failedRecordDeletes.compactMap { failedRecordID, error in
                let staysQueued =
                  queuedRecordZoneChanges.contains(.deleteRecord(failedRecordID))
                  && Self.queuedDeletionErrorCodes.contains(error.code)
                return staysQueued ? nil : failedRecordID
              }
            try removeDeletionMetadata(for: finishedDeletionRecordIDs, db: db)
            if !deletedRecordIDs.isEmpty {
              try UnsyncedRecordID.findAll(deletedRecordIDs).delete().execute(db)
              // NB: A row written again while its deletion was on its way has its flag cleared
              //     (see 'SyncMetadata.insert'), and its metadata still names the record the
              //     server just deleted. It goes up as a new record.
              try SyncMetadata
                .findAll(deletedRecordIDs)
                .where { !$0._isDeleted }
                .update { $0.setLastKnownServerRecord(nil) }
                .execute(db)
            }
            return enqueuedUnsyncedRecordID
          }
        }
        ?? false
      if enqueuedUnsyncedRecordID {
        await handleFetchedRecordZoneChanges(syncEngine: syncEngine)
      }

      await updateQuotaExceeded(
        syncEngine: syncEngine,
        savedRecords: savedRecords,
        failedRecordSaves: failedRecordSaves
      )
    }

    private func updateQuotaExceeded(
      syncEngine: any SyncEngineProtocol,
      savedRecords: [CKRecord],
      failedRecordSaves: [(record: CKRecord, error: CKError)]
    ) async {
      let hasQuotaExceededFailure =
        failedRecordSaves
        .contains(where: { $0.error.code == .quotaExceeded })
      if hasQuotaExceededFailure {
        updateQuotaExceeded(
          isExceeded: true,
          scope: syncEngine.database.databaseScope
        )
      } else if !savedRecords.isEmpty {
        updateQuotaExceeded(
          isExceeded: false,
          scope: syncEngine.database.databaseScope
        )
        await withErrorReporting(.sqliteDataCloudKitFailure) {
          try await enqueueLocallyPendingChanges(scope: syncEngine.database.databaseScope)
        }
      }
      func updateQuotaExceeded(isExceeded: Bool, scope: CKDatabase.Scope) {
        let isExceeded = self.quotaExceeded.withValue { quotaExceeded -> Bool? in
          guard isExceeded != quotaExceeded[scope] else { return nil }
          defer { quotaExceeded[scope] = isExceeded }
          return isExceeded
        }
        guard let isExceeded
        else { return }
        delegate?.syncEngine(self, quotaExceeded: isExceeded, scope: scope)
      }
    }

    private func cacheShare(_ share: CKShare) async throws {
      let metadata = try await withRateLimiting {
        try await container.shareMetadata(for: share, shouldFetchRootRecord: false)
      }
      guard let rootRecordID = metadata.hierarchicalRootRecordID
      else { return }
      try await userDatabase.write { db in
        try SyncMetadata
          .find(rootRecordID)
          .update { $0.share = #bind(share) }
          .execute(db)
      }
    }

    func deleteShares(shareRecordIDs: OrderedSet<CKRecord.ID>) async throws {
      let rootRecordIDs = try await metadatabase.read { db in
        try SyncMetadata
          .where(\.isShared)
          .select { ($0.share, $0.recordName, $0.zoneName, $0.ownerName) }
          .fetchAll(db)
          .compactMap { share, recordName, zoneName, ownerName -> CKRecord.ID? in
            guard let share, shareRecordIDs.contains(share.recordID)
            else { return nil }
            return CKRecord.ID(
              recordName: recordName,
              zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
            )
          }
      }
      try await container.privateCloudDatabase.records(for: rootRecordIDs) { results in
        try await userDatabase.write { db in
          for (rootRecordID, result) in results {
            withErrorReporting(.sqliteDataCloudKitFailure) {
              let rootRecord = try result.get()
              try SyncMetadata
                .find(rootRecordID)
                .update {
                  $0.setLastKnownServerRecord(rootRecord)
                  $0.share = #bind(nil)
                }
                .execute(db)
            }
          }
        }
      }
    }

    private func upsertFromServerRecord(
      _ serverRecord: CKRecord,
      force: Bool = false
    ) async {
      await withErrorReporting(.sqliteDataCloudKitFailure) {
        try await userDatabase.write { db in
          upsertFromServerRecord(serverRecord, force: force, db: db)
        }
      }
    }

    private func upsertFromServerRecord(
      _ serverRecord: CKRecord,
      force: Bool = false,
      db: Database
    ) {
      withErrorReporting(.sqliteDataCloudKitFailure) {
        guard
          let recordPrimaryKey = serverRecord.recordID.recordPrimaryKey,
          serverRecord.encryptedValues[CKRecord.userModificationTimeKey] != nil
        else {
          return
        }

        try SyncMetadata.insert {
          SyncMetadata(
            recordPrimaryKey: recordPrimaryKey,
            recordType: serverRecord.recordType,
            zoneName: serverRecord.recordID.zoneID.zoneName,
            ownerName: serverRecord.recordID.zoneID.ownerName,
            parentRecordPrimaryKey: serverRecord.parent?.recordID.recordPrimaryKey,
            parentRecordType: serverRecord.parent?.recordID.tableName,
            lastKnownServerRecord: serverRecord,
            _lastKnownServerRecordAllFields: serverRecord,
            share: nil,
            userModificationTime: serverRecord.userModificationTime
          )
        } onConflict: {
          ($0.recordPrimaryKey, $0.recordType)
        } doUpdate: {
          if tablesByName[serverRecord.recordType] == nil {
            $0.setLastKnownServerRecord(serverRecord)
          } else {
            $0.zoneName = serverRecord.recordID.zoneID.zoneName
            $0.ownerName = serverRecord.recordID.zoneID.ownerName
          }
        }
        .execute(db)

        guard
          let metadata = try SyncMetadata.find(serverRecord.recordID).fetchOne(db),
          let table = tablesByName[serverRecord.recordType]
        else {
          return
        }

        // NB: A local deletion of this record is still waiting to be sent or confirmed, and it
        //     wins (its metadata stays until then, see 'removeDeletionMetadata'). Writing the
        //     server record would bring the row back while the deletion stays queued: once it is
        //     sent the server record is gone but the local row stays, without metadata, and the
        //     device no longer matches the server. Fetches can deliver this record at any time,
        //     including this device's own earlier saves when its change token predates them.
        guard force || !metadata._isDeleted
        else { return }

        serverRecord.userModificationTime = metadata.userModificationTime

        func open<T>(_ table: some SynchronizableTable<T>) throws {
          var columnNames: [String] = T.TableColumns.writableColumns.map(\.name)
          if !force,
            let allFields = metadata._lastKnownServerRecordAllFields,
            let row = try T.unscoped.find(#sql("\(bind: metadata.recordPrimaryKey)")).fetchOne(db)
          {
            serverRecord.update(
              with: allFields,
              row: T(queryOutput: row),
              columnNames: &columnNames,
              parentForeignKey: foreignKeysByTableName[T.tableName]?.count == 1
                ? foreignKeysByTableName[T.tableName]?.first
                : nil
            )
          }

          do {
            try $_currentZoneID.withValue(serverRecord.recordID.zoneID) {
              try #sql(upsert(table, record: serverRecord, columnNames: columnNames)).execute(db)
            }
            try UnsyncedRecordID.find(serverRecord.recordID).delete().execute(db)
            try SyncMetadata
              .find(serverRecord.recordID)
              .update { $0.setLastKnownServerRecord(serverRecord) }
              .execute(db)
          } catch {
            guard
              let error = error as? DatabaseError,
              error.resultCode == .SQLITE_CONSTRAINT,
              error.extendedResultCode == .SQLITE_CONSTRAINT_FOREIGNKEY
            else {
              throw error
            }
            try UnsyncedRecordID.insert {
              UnsyncedRecordID(record: serverRecord)
            } onConflict: {
              ($0.recordName, $0.zoneName, $0.ownerName)
            } doUpdate: {
              $0.assets = $1.assets
              $0.record = $1.record
            }
            .execute(db)
          }
        }
        try open(table)
      }
    }

    /// The errors after which a failed deletion stays queued.
    ///
    /// CKSyncEngine keeps a change pending when it fails for a reason it retries itself, such as a
    /// network failure or the rate limit, and drops it otherwise. `batchRequestFailed` deletions are
    /// queued again by `handleSentRecordZoneChanges`.
    private static let queuedDeletionErrorCodes: Set<CKError.Code> = [
      .batchRequestFailed,
      .networkFailure,
      .networkUnavailable,
      .notAuthenticated,
      .operationCancelled,
      .requestRateLimited,
      .serviceUnavailable,
      .zoneBusy,
    ]

    /// Removes the metadata of local deletions that will not be sent again.
    ///
    /// A deletion keeps its metadata, flagged with `_isDeleted`, until it leaves the queue, so that
    /// a fetch cannot write the deleted row back while the deletion is on its way (see
    /// `upsertFromServerRecord`). Writing the row again clears the flag (see `SyncMetadata.insert`),
    /// but a row an older version left on the device while flagged can still be here, until the
    /// next start settles it (see `settleReturnedRows`): it is queued to be uploaded as a new
    /// record.
    private func removeDeletionMetadata(
      for recordIDs: some Collection<CKRecord.ID>,
      db: Database
    ) throws {
      guard !recordIDs.isEmpty
      else { return }
      // NB: Matched by record name alone: a zone change can move the metadata of a deleted record
      //     away from the zone its deletion was queued in, and it must not stay behind.
      let recordNames = recordIDs.map(\.recordName)
      let deletedRecords =
        try SyncMetadata
        .where { $0.recordName.in(recordNames) && $0._isDeleted }
        .select { ($0.recordType, $0.recordPrimaryKey) }
        .fetchAll(db)
      guard !deletedRecords.isEmpty
      else { return }
      try SyncMetadata
        .where { $0.recordName.in(recordNames) && $0._isDeleted }
        .delete()
        .execute(db)

      let primaryKeysByRecordType = Dictionary(grouping: deletedRecords, by: \.0)
        .mapValues { $0.map(\.1) }
      $_isSynchronizingChanges.withValue(false) {
        for (recordType, primaryKeys) in primaryKeysByRecordType {
          guard let table = tablesByName[recordType]
          else { continue }
          func open<T>(_: some SynchronizableTable<T>) {
            withErrorReporting(.sqliteDataCloudKitFailure) {
              let primaryKeys: QueryFragment = primaryKeys.map { "\(bind: $0)" }
                .joined(separator: ", ")
              try #sql(
                """
                UPDATE \(T.self) SET \(quote: T.primaryKey.name) = \(quote: T.primaryKey.name)
                WHERE \(quote: T.primaryKey.name) IN (\(primaryKeys))
                """
              )
              .execute(db)
            }
          }
          open(table)
        }
      }
    }

    /// The records among some whose row is on this device, and the shares among them of roots
    /// whose row is.
    private func recordIDsOfRowsOnDevice(
      among recordIDs: [CKRecord.ID]
    ) async -> Set<CKRecord.ID> {
      guard !recordIDs.isEmpty
      else { return [] }
      return await withErrorReporting(.sqliteDataCloudKitFailure) {
        // NB: The records' metadata, keyed by the record ID a deletion of each is queued under: a
        //     share's deletion goes by the share's ID.
        let metadataByDeletedRecordID = try await metadatabase.read { db in
          let metadata = try SyncMetadata.findAll(recordIDs).fetchAll(db)
          var metadataByDeletedRecordID = Dictionary(
            metadata.map { ($0.zonedRecordID, $0) },
            uniquingKeysWith: { first, _ in first }
          )
          let otherRecordIDs = Set(recordIDs).subtracting(metadataByDeletedRecordID.keys)
          if !otherRecordIDs.isEmpty {
            for root in try SyncMetadata.where(\.isShared).fetchAll(db) {
              guard
                let shareRecordID = root.share?.recordID,
                otherRecordIDs.contains(shareRecordID)
              else { continue }
              metadataByDeletedRecordID[shareRecordID] = root
            }
          }
          return metadataByDeletedRecordID
        }
        guard !metadataByDeletedRecordID.isEmpty
        else { return [] }
        return try await userDatabase.read { db in
          var keptRecordIDs: Set<CKRecord.ID> = []
          for (recordID, metadata) in metadataByDeletedRecordID {
            guard let table = tablesByName[metadata.recordType]
            else { continue }
            func open<T>(_: some SynchronizableTable<T>) throws -> Bool {
              try T
                .unscoped
                .where { #sql("\($0.primaryKey) = \(bind: metadata.recordPrimaryKey)") }
                .fetchOne(db) != nil
            }
            if try open(table) {
              keptRecordIDs.insert(recordID)
            }
          }
          return keptRecordIDs
        }
      }
        ?? []
    }

    /// Whether a record exists locally but the server has never confirmed a save of it.
    ///
    /// Only records returned by the server carry a change tag. A last known server record without
    /// one was built locally for a send that never succeeded.
    private func isAwaitingFirstUpload(_ recordID: CKRecord.ID) async -> Bool {
      await withErrorReporting(.sqliteDataCloudKitFailure) {
        try await metadatabase.read { db in
          guard
            let metadata = try SyncMetadata.find(recordID).fetchOne(db),
            !metadata._isDeleted
          else { return false }
          return !(metadata.lastKnownServerRecord?.hasServerChangeTag ?? false)
        }
      }
        ?? false
    }

    private func refreshLastKnownServerRecord(_ record: CKRecord) async {
      await withErrorReporting(.sqliteDataCloudKitFailure) {
        try await userDatabase.write { db in
          let metadata = try SyncMetadata.find(record.recordID).fetchOne(db)
          func updateLastKnownServerRecord() throws {
            try SyncMetadata
              .find(record.recordID)
              .update { $0.setLastKnownServerRecord(record) }
              .execute(db)
          }

          if let lastKnownDate = metadata?.lastKnownServerRecord?._modificationDate {
            if let recordDate = record._modificationDate, lastKnownDate <= recordDate {
              try updateLastKnownServerRecord()
            }
          } else {
            try updateLastKnownServerRecord()
          }
        }
      }
    }

    private func updateQuery<T>(
      for _: some SynchronizableTable<T>,
      record: CKRecord,
      columnNames: some Collection<String>,
      changedColumnNames: some Collection<String>
    ) -> QueryFragment {
      let nonPrimaryKeyChangedColumns =
        changedColumnNames
        .filter {
          $0 != T.primaryKey.name && record.hasSet(key: $0)
        }
      guard
        !nonPrimaryKeyChangedColumns.isEmpty
      else {
        return ""
      }
      var query: QueryFragment = "INSERT INTO \(T.self) ("
      query.append(columnNames.map { "\(quote: $0)" }.joined(separator: ", "))
      query.append(") VALUES (")
      query.append(
        columnNames
          .map { columnName in
            if let asset = record[columnName] as? CKAsset {
              let data = try? asset.fileURL.map { try dataManager.wrappedValue.load($0) }
              if data == nil {
                reportIssue("Asset data not found on disk")
              }
              return data?.queryFragment ?? "NULL"
            } else {
              return record.encryptedValues[columnName]?.queryFragment ?? "NULL"
            }
          }
          .joined(separator: ", ")
      )
      query.append(") ON CONFLICT(\(quote: T.primaryKey.name)) DO UPDATE SET ")
      query.append(" ")
      query.append(
        nonPrimaryKeyChangedColumns
          .map { columnName in
            if let asset = record[columnName] as? CKAsset {
              let data = try? asset.fileURL.map { try dataManager.wrappedValue.load($0) }
              if data == nil {
                reportIssue("Asset data not found on disk")
              }
              return
                "\(quote: columnName) = \(data?.queryFragment ?? #""excluded".\#(quote: columnName)"#)"
            } else {
              return """
                \(quote: columnName) = \
                \(record.encryptedValues[columnName]?.queryFragment ?? #""excluded".\#(quote: columnName)"#)
                """
            }
          }
          .joined(separator: ",")
      )
      return query
    }
  }

  @available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
  extension CKSyncEngine.PendingRecordZoneChange {
    var id: CKRecord.ID? {
      switch self {
      case .saveRecord(let id):
        return id
      case .deleteRecord(let id):
        return id
      @unknown default:
        reportIssue(
          """
          Unrecognized 'PendingRecordZoneChange'. Open an issue at \
          https://github.com/pointfreeco/sqlite-data if you run into this.
          """
        )
        return nil
      }
    }
  }

  extension CKRecord.ID {
    var tableName: String? {
      guard
        let i = recordName.utf8.lastIndex(of: UTF8.CodeUnit(ascii: ":")),
        let j = recordName.utf8.index(i, offsetBy: 1, limitedBy: recordName.utf8.endIndex)
      else { return nil }
      let recordTypeBytes = recordName.utf8[j...]
      guard !recordTypeBytes.isEmpty else { return nil }
      return String(Substring(recordTypeBytes))
    }

    var recordPrimaryKey: String? {
      guard
        let i = recordName.utf8.lastIndex(of: UTF8.CodeUnit(ascii: ":"))
      else { return nil }
      let recordPrimaryKeyBytes = recordName.utf8[..<i]
      guard
        !recordPrimaryKeyBytes.isEmpty
      else { return nil }
      return String(Substring(recordPrimaryKeyBytes))
    }
  }

  extension CKRecordZone.ID {
    fileprivate var databaseScope: CKDatabase.Scope {
      ownerName == CKCurrentUserDefaultName ? .private : .shared
    }
  }

  extension String {
    package static let sqliteDataCloudKitSchemaName = "sqlitedata_icloud"
    package static let sqliteDataCloudKitFailure = "SQLiteData CloudKit Failure"
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension URL {
    package static func metadatabase(
      databasePath: String,
      containerIdentifier: String?
    ) throws -> URL {
      let databasePath = databasePath.isEmpty ? ":memory:" : databasePath
      guard let databaseURL = URL(string: databasePath)
      else {
        struct InvalidDatabasePath: Error {}
        throw InvalidDatabasePath()
      }
      guard !databaseURL.isInMemory
      else {
        return URL(string: "file:\(String.sqliteDataCloudKitSchemaName)?mode=memory&cache=shared")!
      }
      return
        databaseURL.deletingLastPathComponent().appending(
          component: ".\(databaseURL.deletingPathExtension().lastPathComponent)"
        )
        .appendingPathExtension("metadata\(containerIdentifier.map { "-\($0)" } ?? "").sqlite")
    }

    package var isInMemory: Bool {
      path.isEmpty
        || path.hasPrefix(":memory:")
        || absoluteString.hasPrefix(":memory:")
        || URLComponents(url: self, resolvingAgainstBaseURL: false)?
          .queryItems?
          .contains(where: { $0.name == "mode" && $0.value == "memory" })
          == true
    }
  }

  /// The starts of a sync engine, while their sync engines are being created (see `start`).
  private struct Startup {
    /// Increased by every stop, so that a start creating sync engines when sync stops throws them
    /// away.
    var generation = 0
    /// The latest start, until its sync engines are created.
    var pending: PendingStart?
  }

  private struct PendingStart {
    /// The value of ``Startup/generation`` when the start began.
    let generation: Int
    /// Creates the sync engines and puts them in place, unless a stop called the start off.
    /// Returns whether it put them in place.
    let creation: Task<Bool, Never>
    /// The creation of the sync engines, then the work of the start.
    let task: Task<Void, Never>
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  package struct SyncEngines {
    private let rawValue: (private: any SyncEngineProtocol, shared: any SyncEngineProtocol)?
    init() {
      rawValue = nil
    }
    init(private: any SyncEngineProtocol, shared: any SyncEngineProtocol) {
      rawValue = (`private`, shared)
    }
    var isRunning: Bool {
      rawValue != nil
    }
    package var `private`: (any SyncEngineProtocol)? {
      guard let `private` = rawValue?.private
      else {
        if isRunning {
          reportIssue("Private sync engine has not been set.")
        }
        return nil
      }
      return `private`
    }
    package var `shared`: (any SyncEngineProtocol)? {
      guard let `shared` = rawValue?.shared
      else {
        if isRunning {
          reportIssue("Shared sync engine has not been set.")
        }
        return nil
      }
      return `shared`
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension Database {
    /// Attaches the metadatabase to an existing database connection.
    ///
    /// Invoke this method when preparing your database connection in order to allow querying the
    /// ``SyncMetadata`` table (see <doc:CloudKitSync#Accessing-CloudKit-metadata> for more info):
    ///
    /// ```swift
    /// func appDatabase() -> any DatabaseWriter {
    ///   var configuration = Configuration()
    ///   configuration.prepareDatabase = { db in
    ///     db.attachMetadatabase()
    ///     …
    ///   }
    /// }
    /// ```
    ///
    /// By default this method will use the container identifier assigned in your app's
    /// entitlements. If you wish to use a different container identifier then you can provide
    /// the `containerIdentifier` argument.
    ///
    /// See <doc:PreparingDatabase> for more information on preparing your database.
    ///
    /// - Parameter containerIdentifier: The identifier of the CloudKit container used to
    /// synchronize data. Defaults to the value set in the app's entitlements.
    public func attachMetadatabase(containerIdentifier: String? = nil) throws {
      @Dependency(\.context) var context
      let containerIdentifier =
        containerIdentifier
        ?? ModelConfiguration(groupContainer: .automatic).cloudKitContainerIdentifier
        ?? (context != .live ? "container" : nil)

      guard let containerIdentifier else {
        throw SyncEngine.SchemaError.noCloudKitContainer
      }

      let databasePath = try PragmaDatabaseList.select(\.file).fetchOne(self)
      guard let databasePath else {
        struct PathError: Error {}
        throw SyncEngine.SchemaError(
          reason: .unknown,
          debugDescription: """
            Expected to load a database path from the connection, but failed to do so.
            """
        )
      }
      let url = try URL.metadatabase(
        databasePath: databasePath,
        containerIdentifier: containerIdentifier
      )
      let path = url.isInMemory ? url.absoluteString : url.path(percentEncoded: false)
      let database: any DatabaseWriter =
        url.isInMemory
        ? try DatabaseQueue(path: path)
        : try DatabasePool(path: path)
      _ = try database.read { db in
        try #sql("SELECT 1").execute(db)
      }
      try #sql(
        """
        ATTACH DATABASE \(bind: path) AS \(quote: .sqliteDataCloudKitSchemaName)
        """
      )
      .execute(self)
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngine {
    package struct SchemaError: LocalizedError {
      package enum Reason {
        case cycleDetected
        case invalidForeignKey(ForeignKey)
        case invalidForeignKeyAction(ForeignKey)
        case invalidTableName(String)
        case metadatabaseMismatch(attachedPath: String, syncEngineConfiguredPath: String)
        case noCloudKitContainer
        case nonNullColumnsWithoutDefault(tableName: String, columnNames: [String])
        case unknown
        case uniquenessConstraint
      }
      package let reason: Reason
      package let debugDescription: String

      package var errorDescription: String? {
        "Could not synchronize data with iCloud."
      }

      static let noCloudKitContainer = Self(
        reason: .noCloudKitContainer,
        debugDescription: """
          No default CloudKit container found. Make sure to enable iCloud entitlements in your \
          app's "Signing & Capabilities" and add a container identifier.
          """
      )
    }

    fileprivate func validateSchema() throws {
      let tableNames = Set(tables.map { $0.base.tableName })
      for tableName in tableNames {
        if tableName.contains(":") {
          throw SyncEngine.SchemaError(
            reason: .invalidTableName(tableName),
            debugDescription: "Table name contains invalid character ':'"
          )
        }
      }
      try userDatabase.read { db in
        for (tableName, foreignKeys) in foreignKeysByTableName {
          let invalidForeignKey = foreignKeys.first(where: { tablesByName[$0.table] == nil })
          if let invalidForeignKey {
            throw SyncEngine.SchemaError(
              reason: .invalidForeignKey(invalidForeignKey),
              debugDescription: """
                Foreign key \
                \(tableName.debugDescription).\(invalidForeignKey.from.debugDescription) \
                references table \(invalidForeignKey.table.debugDescription) that is not \
                synchronized. Update 'SyncEngine.init' to synchronize \
                \(invalidForeignKey.table.debugDescription). 
                """
            )
          }

          if foreignKeys.count == 1,
            let foreignKey = foreignKeys.first,
            [.restrict, .noAction].contains(foreignKey.onDelete)
          {
            throw SyncEngine.SchemaError(
              reason: .invalidForeignKeyAction(foreignKey),
              debugDescription: """
                Foreign key \(tableName.debugDescription).\(foreignKey.from.debugDescription) \
                action not supported. Must be 'CASCADE', 'SET DEFAULT' or 'SET NULL'.
                """
            )
          }
        }

        for table in tables {
          func open<T>(_: some SynchronizableTable<T>) throws {
            let columnsWithUniqueConstraints = try PragmaIndexList<T>
              .where { $0.isUnique && $0.origin.neq("pk") }
              .select(\.name)
              .fetchAll(db)
            if !columnsWithUniqueConstraints.isEmpty {
              throw SyncEngine.SchemaError(
                reason: .uniquenessConstraint,
                debugDescription: """
                  Uniqueness constraints are not supported for synchronized tables.
                  """
              )
            }
          }
          try open(table)
        }
      }
    }
  }

  package protocol SynchronizableTable<Base>: Hashable, Sendable {
    associatedtype Base: PrimaryKeyedTable & _SendableMetatype
    where
      Base.PrimaryKey.QueryOutput: IdentifierStringConvertible,
      Base.TableColumns.PrimaryColumn: WritableTableColumnExpression
    var base: Base.Type { get }
  }

  package struct SynchronizedTable<
    Base: PrimaryKeyedTable & _SendableMetatype
  >: SynchronizableTable
  where
    Base.PrimaryKey.QueryOutput: IdentifierStringConvertible,
    Base.TableColumns.PrimaryColumn: WritableTableColumnExpression
  {
    package init(for table: Base.Type = Base.self) {}
    package var base: Base.Type { Base.self }
  }

  private struct HashableSynchronizedTable: Hashable {
    let type: any SynchronizableTable
    init(_ type: any SynchronizableTable) {
      self.type = type
    }
    func hash(into hasher: inout Hasher) {
      hasher.combine(ObjectIdentifier(type.base))
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.type.base == rhs.type.base
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  private func tablesByOrder(
    userDatabase: UserDatabase,
    tables: [any SynchronizableTable],
    tablesByName: [String: any SynchronizableTable]
  ) throws -> [String: Int] {
    let tableDependencies = try userDatabase.read { db in
      var dependencies: OrderedDictionary<HashableSynchronizedTable, [any SynchronizableTable]> =
        [:]
      for table in tables {
        func open<T>(_: some SynchronizableTable<T>) throws -> [String] {
          try PragmaForeignKeyList<T>
            .order(by: \.table)
            .select(\.table)
            .fetchAll(db)
        }
        let toTables = try open(table)
        for toTable in toTables {
          guard let toTableType = tablesByName[toTable]
          else { continue }
          dependencies[HashableSynchronizedTable(table), default: []].append(toTableType)
        }
      }
      return dependencies
    }

    var visited = Set<HashableSynchronizedTable>()
    var marked = Set<HashableSynchronizedTable>()
    var result: [String: Int] = [:]
    for table in tableDependencies.keys {
      try visit(table: table)
    }
    // NB: Tables that neither reference nor are referenced by another synchronized table still
    //     need a position. Without one, the comparator that sorts pending changes is not a strict
    //     weak ordering, and the sort can send a child record before its parent.
    for table in tables {
      try visit(table: HashableSynchronizedTable(table))
    }
    return result

    func visit(table: HashableSynchronizedTable) throws {
      guard !visited.contains(table)
      else { return }
      guard !marked.contains(table)
      else {
        throw SyncEngine.SchemaError(
          reason: .cycleDetected,
          debugDescription: """
            Cycles are not currently permitted in schemas, e.g. a table that references itself.
            """
        )
      }

      marked.insert(table)
      for dependency in tableDependencies[table] ?? [] {
        try visit(table: HashableSynchronizedTable(dependency))
      }
      marked.remove(table)
      visited.insert(table)
      result[table.type.base.tableName] = result.count
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncMetadata {
    /// The record's ID, in the zone the metadata names.
    fileprivate var zonedRecordID: CKRecord.ID {
      CKRecord.ID(
        recordName: recordName,
        zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
      )
    }

    /// The IDs a deletion of the record can be queued under: 'didDelete' takes the zone of the
    /// last known server record, which a zone change can leave behind the metadata's.
    fileprivate var deletionRecordIDs: [CKRecord.ID] {
      var recordIDs = [zonedRecordID]
      if let lastKnownRecordID = lastKnownServerRecord?.recordID,
        lastKnownRecordID != zonedRecordID
      {
        recordIDs.append(lastKnownRecordID)
      }
      return recordIDs
    }
  }

  /// A record whose row a fetched deletion deleted or changed, without deleting the record
  /// itself (see `SyncEngine.settleDependents`).
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  private struct Dependent: Sendable {
    /// Its metadata, read before the deletion.
    let metadata: SyncMetadata
    /// Whether the row was deleted, rather than having its reference cleared.
    let isDeleted: Bool
  }

  /// What a delete reaches beyond the rows it names (see `SyncEngine.dependentRows`).
  private struct DependentRows {
    /// Rows deleted with them: primary keys, as the metadata stores them, by table name.
    var deleted: [String: Set<String>] = [:]
    /// Rows whose reference to them is cleared: primary keys by table name.
    var changed: [String: Set<String>] = [:]

    var deletedRecordNames: Set<String> {
      Self.recordNames(deleted)
    }

    var changedRecordNames: Set<String> {
      Self.recordNames(changed)
    }

    var recordNames: [String] {
      Array(deletedRecordNames.union(changedRecordNames))
    }

    private static func recordNames(_ primaryKeysByTableName: [String: Set<String>]) -> Set<String> {
      Set(
        primaryKeysByTableName.flatMap { tableName, primaryKeys in
          primaryKeys.map { "\($0):\(tableName)" }
        }
      )
    }
  }

  /// A row on the device whose metadata was flagged `_isDeleted` (see `settleReturnedRows`).
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  private struct ReturnedRow: Sendable {
    let metadata: SyncMetadata
    /// Whether the row holds a change the server never received.
    let isChanged: Bool
    /// Whether the row stays: someone took it back after it returned.
    var isKept: Bool

    var recordID: CKRecord.ID {
      metadata.zonedRecordID
    }

    var isPrivate: Bool {
      recordID.zoneID.ownerName == CKCurrentUserDefaultName
    }

    /// The deletions of the row, and of its share, that may still be queued.
    var deletionRecordIDs: [CKRecord.ID] {
      metadata.deletionRecordIDs + (metadata.share.map { [$0.recordID] } ?? [])
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension Updates<SyncMetadata> {
    mutating func setLastKnownServerRecord(_ lastKnownServerRecord: CKRecord?) {
      self.zoneName = lastKnownServerRecord?.recordID.zoneID.zoneName ?? self.zoneName
      self.ownerName = lastKnownServerRecord?.recordID.zoneID.ownerName ?? self.ownerName
      self.lastKnownServerRecord = #bind(lastKnownServerRecord)
      self._lastKnownServerRecordAllFields = #bind(lastKnownServerRecord)
      if let lastKnownServerRecord {
        self.userModificationTime = #sql(
          """
          max(\(self.userModificationTime), \(lastKnownServerRecord.userModificationTime))
          """
        )
      }
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  private func upsert<T>(
    _: some SynchronizableTable<T>,
    record: CKRecord,
    columnNames: some Collection<String>
  ) -> QueryFragment {
    let setColumnNames = T.TableColumns.writableColumns.map(\.name)
      .filter { record.hasSet(key: $0) }
    guard !setColumnNames.isEmpty
    else {
      return ""
    }
    let columnNames = columnNames.filter { setColumnNames.contains($0) }
    let hasNonPrimaryKeyColumns = columnNames.contains { $0 != T.primaryKey.name }
    var query: QueryFragment = "INSERT INTO \(T.self) ("
    query.append(setColumnNames.map { "\(quote: $0)" }.joined(separator: ", "))
    query.append(") VALUES (")
    query.append(
      setColumnNames
        .map { columnName in
          if let asset = record[columnName] as? CKAsset {
            @Dependency(\.dataManager) var dataManager
            return (try? asset.fileURL.map { try dataManager.load($0) })?
              .queryFragment ?? "NULL"
          } else {
            return record.encryptedValues[columnName]?.queryFragment ?? "NULL"
          }
        }
        .joined(separator: ", ")
    )
    query.append(") ON CONFLICT(\(quote: T.primaryKey.name)) DO")
    if hasNonPrimaryKeyColumns {
      query.append(" UPDATE SET ")
      query.append(
        columnNames
          .filter { $0 != T.primaryKey.name }
          .map {
            """
            \(quote: $0) = "excluded".\(quote: $0)
            """
          }
          .joined(separator: ", ")
      )
    } else {
      query.append(" NOTHING")
    }
    return query
  }

  @TaskLocal package var _isSynchronizingChanges = false
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @TaskLocal package var _currentZoneID: CKRecordZone.ID?
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @DatabaseFunction("sqlitedata_icloud_currentZoneName")
  func currentZoneName() -> String? {
    _currentZoneID?.zoneName
  }
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @DatabaseFunction("sqlitedata_icloud_currentOwnerName")
  func currentOwnerName() -> String? {
    _currentZoneID?.ownerName
  }

  private struct ActivityCounts {
    var sendingChangesCount = 0
    var fetchingChangesCount = 0
  }

  #if DEBUG
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    private struct NextRecordZoneChangeBatchLoggingState {
      var events: [String] = []
      var recordTypes: [String] = []
      var recordNames: [String] = []
      var tabularDescription: String? {
        guard !events.isEmpty
        else { return nil }
        var dataFrame: DataFrame = [
          "event": events,
          "recordType": recordTypes,
          "recordName": recordNames,
        ]
        dataFrame.sort(
          on: ColumnID("event", String.self),
          ColumnID("recordType", String.self),
          ColumnID("recordName", String.self)
        )
        var formattingOptions = FormattingOptions(
          maximumLineWidth: 120,
          maximumCellWidth: 80,
          maximumRowCount: 50,
          includesColumnTypes: false
        )
        formattingOptions.includesRowAndColumnCounts = false
        formattingOptions.includesRowIndices = false
        return
          dataFrame
          .description(options: formattingOptions)
          .replacing("\n", with: "\n  ")
      }
    }
  #endif
#endif
