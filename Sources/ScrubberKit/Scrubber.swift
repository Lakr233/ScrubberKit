//
//  Scrubber.swift
//  Playground
//
//  Created by 秋星桥 on 2/17/25.
//

@preconcurrency import Combine
import Foundation

public class Scrubber: @unchecked Sendable {
    public let query: String
    public let options: ScrubberOptions

    public init(query: String, options: ScrubberOptions = .init()) {
        self.query = query
        self.options = options
    }

    private(set) var isCancelled: Bool = false
    @MainActor private var cores: [UUID: ScrubWorker] = [:]
    @MainActor private var result: [URL: Document?] = [:]
    @MainActor private var runCancellables: Set<AnyCancellable> = []

    public var timeout: TimeInterval = 10

    @MainActor
    public var documents: [Document] {
        result.values.compactMap(\.self).sorted { lhs, rhs in
            lhs.url.absoluteString < rhs.url.absoluteString
        }
    }

    public let progress: ScrubberProgress = .init()
    let concurrentControl = DispatchSemaphore(value: max(
        4,
        ProcessInfo.processInfo.processorCount * 2
    ))
    let dispatchGroup = DispatchGroup()
    @MainActor private static var standaloneWorkers: [UUID: ScrubWorker] = [:]

    @MainActor
    public func run(
        limitation: Int? = nil,
        _ completion: @escaping @Sendable ([Document]) -> Void,
        onProgress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) {
        assert(Thread.isMainThread)

        runCancellables.forEach { $0.cancel() }
        runCancellables.removeAll()
        let limitation = limitation ?? 20

        progress.updatePublisher
            .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] progress in
                onProgress(progress)
                self?.cancelIf(limitation: limitation, lastTenPercent: true)
            }
            .store(in: &runCancellables)

        if let urlsReranker = options.urlsReranker {
            search(urlsReranker, topN: limitation)
        } else {
            search()
        }

        DispatchQueue.global().async {
            _ = self.dispatchGroup.wait(timeout: .now() + 45)
            DispatchQueue.main.async {
                self.runCancellables.forEach { $0.cancel() }
                self.runCancellables.removeAll()
                self.cancel()
                let result = self.result.compactMap(\.value)
                let resultProgress = Progress(totalUnitCount: .init(result.count))
                resultProgress.completedUnitCount = resultProgress.totalUnitCount
                completion(result)
                onProgress(resultProgress)
            }
        }
    }

    @MainActor
    public func cancel() {
        assert(Thread.isMainThread)
        isCancelled = true
        cores.forEach { $0.value.cancel() }
        cores.removeAll()
        result = result.filter { $0.value != nil }
    }

    @MainActor
    @discardableResult
    func dispatchWorker(
        retrievingURL: URL,
        onComplete: @escaping @Sendable (ScrubWorker.ScrubResult?) -> Void
    ) -> ScrubWorker? {
        assert(Thread.isMainThread)
        guard !isCancelled else {
            onComplete(nil)
            return nil
        }
        let id = UUID()
        let core = ScrubWorker(baseUrl: retrievingURL, softTimeout: timeout) { result in
            DispatchQueue.main.async { self.cores.removeValue(forKey: id) }
            onComplete(result)
        }
        cores[id] = core
        return core
    }

    @MainActor
    private func search() {
        assert(Thread.isMainThread)
        for engine in enabledEngines {
            progress.update(engine: engine, status: .fetching)
            guard let query = engine.makeSearchQueryRequest(query) else {
                progress.update(engine: engine, status: .completed(result: 0))
                continue
            }
            dispatchGroup.enterBackground { leaver in
                self.scrub(url: query, retry: 2) { result in
                    let searchResults = engine.parseSearchResult(result?.document ?? "")
                    self.progress.update(engine: engine, status: .completed(result: searchResults.count))
                    DispatchQueue.main.async {
                        self.process(candidates: searchResults, engine: engine)
                        leaver()
                    }
                }
            }
        }
    }

    @MainActor
    private func process(candidates: [URL], engine: ScrubEngine) {
        assert(Thread.isMainThread)

        var jobs: [URL] = []
        for url in candidates where result[url] == nil {
            self.result[url] = nil
            jobs.append(url)
            progress.update(url: url, status: .pending)
        }
        let pendingJobs = jobs

        DispatchQueue.global().async {
            for job in pendingJobs {
                self.concurrentControl.wait()
                self.dispatchGroup.enterBackground { leaver in
                    self.progress.update(url: job, status: .fetching)
                    self.process(candidate: job, engine: engine) {
                        self.concurrentControl.signal()
                        leaver()
                    }
                }
            }
        }
    }

    private func process(candidate: URL, engine: ScrubEngine, completion: @escaping @Sendable () -> Void) {
        assert(!Thread.isMainThread)
        progress.update(url: candidate, status: .fetching)
        scrub(url: candidate, retry: 2) { result in
            assert(!Thread.isMainThread)
            guard let result,
                  let content = Self.finalize(
                      document: result.document,
                      markdownDocument: result.markdownDocument,
                      engine: engine,
                      url: result.url
                  )
            else {
                self.progress.update(url: candidate, status: .completed)
                completion()
                return
            }
            DispatchQueue.main.async {
                self.process(result: content)
                self.progress.update(url: candidate, status: .completed)
                completion()
            }
        }
    }

    @MainActor
    private func process(result: Document) {
        assert(Thread.isMainThread)
        guard !isCancelled else { return }
        self.result[result.url] = result
    }

    @MainActor
    private func cancelIf(
        limitation: Int? = nil,
        lastTenPercent: Bool = false
    ) {
        guard !isCancelled else { return }
        guard progress.engineStatus.count == progress.engineStatusCompletedCount else { return }

        if let limitation {
            if documents.count >= limitation {
                cancel()
                return
            }
        }

        if lastTenPercent {
            let comp = progress.fetchedStatusCompletedCount
            let total = progress.fetchedStatus.count
            guard total > 5 else { return }
            if comp >= Int(Double(total) * 0.9) - 1 {
                cancel()
                return
            }
        }
    }
}

public extension Scrubber {
    @MainActor
    static func document(for url: URL, completion: @escaping @Sendable (Document?) -> Void) {
        var completionCalled = false
        let finish: @MainActor @Sendable (Document?) -> Void = { doc in
            guard !completionCalled else { return }
            completionCalled = true
            completion(doc)
        }

        let id = UUID()
        let worker = ScrubWorker(baseUrl: url, softTimeout: 15) { result in
            Task { @MainActor in
                Self.standaloneWorkers.removeValue(forKey: id)
            }
            DispatchQueue.global().async {
                let doc = finalize(
                    document: result.document,
                    markdownDocument: result.markdownDocument,
                    engine: nil,
                    url: result.url
                )
                Task { @MainActor in
                    finish(doc)
                }
            }
        }
        Self.standaloneWorkers[id] = worker

        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            Self.standaloneWorkers.removeValue(forKey: id)
            finish(nil)
        }
    }
}

extension Scrubber {
    @MainActor
    private func search(_ reranker: URLsReranker, topN: Int) {
        assert(Thread.isMainThread)
        let searchGroup = DispatchGroup()
        let enabledEngines = enabledEngines
        let searchSnippets = LockedBox<[SearchSnippet]>([])

        for engine in enabledEngines {
            progress.update(engine: engine, status: .fetching)
            guard let query = engine.makeSearchQueryRequest(query)
            else {
                progress.update(
                    engine: engine, status: .completed(result: 0)
                )
                continue
            }

            searchGroup.enterBackground { leaver in
                self.scrub(url: query, retry: 2) { result in
                    let snippets = engine.parseSearchSnippet(
                        result?.document ?? ""
                    )
                    searchSnippets.withLock { $0.append(contentsOf: snippets) }
                    leaver()
                }
            }
        }

        dispatchGroup.enterBackground { leaver in
            searchGroup.wait()

            let snippets = reranker.ranking(searchSnippets.withLock { $0 })

            let groupedSnippets = Dictionary(
                grouping: snippets.prefix(topN),
                by: { $0.engine }
            )

            for (engine, snippets) in groupedSnippets {
                self.dispatchGroup.enterBackground { leaver in
                    let searchResults = snippets.map(\.url)

                    self.progress.update(
                        engine: engine,
                        status: .completed(result: searchResults.count)
                    )

                    DispatchQueue.main.async {
                        self.process(candidates: searchResults, engine: engine)
                        leaver()
                    }
                }
            }

            let missingEngines = Set(enabledEngines).subtracting(groupedSnippets.keys)
            for engine in missingEngines {
                self.progress.update(engine: engine, status: .completed(result: 0))
            }

            leaver()
        }
    }
}

private extension Scrubber {
    @MainActor
    var enabledEngines: [ScrubEngine] {
        let disabledEngines = ScrubberConfiguration.disabledEngines
        return ScrubEngine.allCases.filter { engine in
            !disabledEngines.contains(engine)
        }
    }
}
