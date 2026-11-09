#if canImport(CloudKit)
  import ConcurrencyExtras
  import Foundation
  import SQLiteData

  /// Holds back the creation of a test's sync engines, the way `CKSyncEngine` takes seconds to
  /// decode a large saved state on a device (13 to 14 seconds for 15 MB, measured in 2026).
  ///
  /// The gate is open unless a test closes it, so tests that don't use it are unaffected. A closed
  /// gate opens by itself after 10 seconds, so that a test that never opens it fails instead of
  /// hanging (see ``openedByItself``).
  final class EngineBuildGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = true
    private var holdsAfterPrivateEngine = false
    private var deadline = Date.distantFuture
    private var didOpenByItself = false
    private var builds = 0
    private var buildsInProgress = 0
    private var mostBuildsInProgress = 0
    private var buildsOnMainThread = 0
    private var privateEngineCount = 0
    // NB: Weak: a private engine holds its sync engine, which holds the closure that holds this
    //     gate, and a strong reference would keep every test's databases open.
    private weak var lastPrivateEngine: MockSyncEngine?

    /// Closes the gate before the sync engines are created.
    func close() {
      condition.lock()
      isOpen = false
      holdsAfterPrivateEngine = false
      deadline = Date(timeIntervalSinceNow: 10)
      condition.unlock()
    }

    /// Closes the gate once the private sync engine is created, while the shared one is still to
    /// be created.
    func closeAfterPrivateEngine() {
      condition.lock()
      isOpen = false
      holdsAfterPrivateEngine = true
      deadline = Date(timeIntervalSinceNow: 10)
      condition.unlock()
    }

    /// Whether the gate had to open by itself because the test never opened it.
    var openedByItself: Bool {
      condition.lock()
      defer { condition.unlock() }
      return didOpenByItself
    }

    func open() {
      condition.lock()
      isOpen = true
      condition.broadcast()
      condition.unlock()
    }

    /// Called before the sync engines are created. Waits while the gate is closed.
    func pass() {
      condition.lock()
      defer { condition.unlock() }
      builds += 1
      buildsInProgress += 1
      mostBuildsInProgress = max(mostBuildsInProgress, buildsInProgress)
      if Thread.isMainThread {
        buildsOnMainThread += 1
      }
      if !holdsAfterPrivateEngine {
        waitWhileClosed()
      }
      buildsInProgress -= 1
    }

    /// Called once the private sync engine is created. Waits while the gate is closed, when it was
    /// closed with ``closeAfterPrivateEngine()``.
    func privateEngineCreated(_ privateEngine: MockSyncEngine) {
      condition.lock()
      defer { condition.unlock() }
      privateEngineCount += 1
      lastPrivateEngine = privateEngine
      if holdsAfterPrivateEngine {
        waitWhileClosed()
      }
    }

    /// Waits until a private sync engine has been created `count` times, and returns the last one.
    func waitForPrivateEngine(
      _ count: Int = 1,
      upTo limit: Duration = .seconds(5)
    ) async -> MockSyncEngine? {
      let start = ContinuousClock.now
      while true {
        let privateEngine: MockSyncEngine? = {
          condition.lock()
          defer { condition.unlock() }
          return privateEngineCount >= count ? lastPrivateEngine : nil
        }()
        if let privateEngine {
          return privateEngine
        }
        guard ContinuousClock.now - start < limit
        else { return nil }
        try? await Task.sleep(for: .milliseconds(5))
      }
    }

    /// Waits while the gate is closed. Called with the condition locked.
    private func waitWhileClosed() {
      while !isOpen {
        if !condition.wait(until: deadline) {
          isOpen = true
          didOpenByItself = true
        }
      }
    }

    /// How many times the sync engines were created.
    var buildCount: Int {
      condition.lock()
      defer { condition.unlock() }
      return builds
    }

    /// The most sets of sync engines that were being created at the same time.
    var mostBuildsAtOnce: Int {
      condition.lock()
      defer { condition.unlock() }
      return mostBuildsInProgress
    }

    /// How many times the sync engines were created on the main thread.
    var buildsOnMain: Int {
      condition.lock()
      defer { condition.unlock() }
      return buildsOnMainThread
    }

    /// Waits until the sync engines have started being created `count` times.
    func waitForBuilds(_ count: Int, upTo limit: Duration = .seconds(5)) async -> Bool {
      let start = ContinuousClock.now
      while buildCount < count {
        guard ContinuousClock.now - start < limit
        else { return false }
        try? await Task.sleep(for: .milliseconds(5))
      }
      return true
    }
  }

  /// Work started on its own task, to check whether it has to wait for something.
  ///
  /// NB: Not a detached task: the work sees the test's dependencies, such as its mock containers.
  ///     The task runs off the main actor all the same, as it is started from a nonisolated
  ///     initializer.
  struct Probe: Sendable {
    let task: Task<Void, any Error>
    private let isDone: LockIsolated<Bool>

    init(_ work: @escaping @Sendable () async throws -> Void) {
      let isDone = LockIsolated(false)
      self.isDone = isDone
      task = Task {
        try await work()
        isDone.setValue(true)
      }
    }

    /// Whether the work finished within `limit`.
    func finishes(within limit: Duration = .milliseconds(500)) async -> Bool {
      let start = ContinuousClock.now
      while !isDone.value {
        guard ContinuousClock.now - start < limit
        else { return false }
        try? await Task.sleep(for: .milliseconds(5))
      }
      return true
    }
  }
#endif
