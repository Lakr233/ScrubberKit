//
//  Scrubber+Progress.swift
//  Playground
//
//  Created by 秋星桥 on 2/17/25.
//

import Combine
import Foundation

public extension Scrubber {
    class ScrubberProgress: ObservableObject, @unchecked Sendable {
        public enum EngineStatus: Sendable {
            case fetching
            case completed(result: Int)
        }

        public enum FetchStatus: Sendable {
            case pending
            case fetching
            case completed
        }

        @Published public private(set) var engineStatus: [ScrubEngine: EngineStatus] = [:] {
            didSet { updatePublisher.send(progerss) }
        }

        public var engineStatusCompletedCount: Int {
            engineStatus.values.count(where: { status in
                switch status {
                case .fetching: false
                case .completed: true
                }
            })
        }

        public var allEngineReturnsValue: Bool {
            engineStatus.values.allSatisfy {
                switch $0 {
                case .fetching: false
                case let .completed(value): value > 0
                }
            }
        }

        @Published public private(set) var fetchedStatus: [URL: FetchStatus] = [:] {
            didSet { updatePublisher.send(progerss) }
        }

        public var fetchingStatusCount: Int {
            fetchedStatus.values.count(where: { status in
                switch status {
                case .pending: false
                case .fetching: true
                case .completed: false
                }
            })
        }

        public var fetchedStatusCompletedCount: Int {
            fetchedStatus.values.count(where: { status in
                switch status {
                case .pending: false
                case .fetching: false
                case .completed: true
                }
            })
        }

        public let updatePublisher: PassthroughSubject<Progress, Never> = .init()

        @Published var currentFetching: URL? = nil

        public var progerss: Progress {
            let progress = Progress()
            progress.totalUnitCount += Int64(engineStatus.count)
            progress.completedUnitCount += Int64(engineStatusCompletedCount)
            progress.totalUnitCount += Int64(fetchedStatus.count)
            progress.completedUnitCount += Int64(fetchedStatusCompletedCount)
            return progress
        }

        public var isCompleted: Bool {
            [
                engineStatusCompletedCount <= 0,
                fetchedStatusCompletedCount <= 0,
            ].allSatisfy(\.self)
        }

        private func ensureMainThread(_ block: @escaping @Sendable () -> Void) {
            if Thread.isMainThread {
                block()
            } else {
                DispatchQueue.main.async(execute: block)
            }
        }

        func update(engine: ScrubEngine, status: EngineStatus) {
            ensureMainThread { self.engineStatus[engine] = status }
        }

        func update(url: URL, status: FetchStatus) {
            ensureMainThread { self.fetchedStatus[url] = status }
        }

        init() {}
    }
}
