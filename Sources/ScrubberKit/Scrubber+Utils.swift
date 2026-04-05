//
//  Scrubber+Utils.swift
//  Playground
//
//  Created by 秋星桥 on 2/17/25.
//

import Foundation

extension Scrubber {
    func scrub(url: URL, retry: Int, completion: @escaping @Sendable (ScrubWorker.ScrubResult?) -> Void) {
        assert(!Thread.isMainThread)

        let completionIsCalled = LockedBox(false)
        let finish: @Sendable (ScrubWorker.ScrubResult?) -> Void = { result in
            let shouldComplete = completionIsCalled.withLock { value in
                guard !value else { return false }
                value = true
                return true
            }
            guard shouldComplete else { return }
            completion(result)
        }
        defer { finish(nil) }

        var round = 0
        while retry > round, !isCancelled, !completionIsCalled.withLock(\.self) {
            round += 1
            let semaphore = DispatchSemaphore(value: 0)
            scrub(url: url) { result in
                defer { semaphore.signal() }
                guard let result else { return }
                finish(result)
            }
            let isTimeOut = semaphore.wait(timeout: .now() + timeout)
            if isTimeOut == .timedOut { return }
        }
    }

    func scrub(url: URL, completion: @escaping @Sendable (ScrubWorker.ScrubResult?) -> Void) {
        assert(!Thread.isMainThread)
        guard !isCancelled else { return }

        let isCompletionCalled = LockedBox(false)
        let finish: @Sendable (ScrubWorker.ScrubResult?) -> Void = { result in
            let shouldComplete = isCompletionCalled.withLock { value in
                guard !value else { return false }
                value = true
                return true
            }
            guard shouldComplete else { return }
            DispatchQueue.global().async { completion(result) }
        }

        DispatchQueue.main.async {
            self.dispatchWorker(retrievingURL: url, onComplete: finish)
        }
    }
}
