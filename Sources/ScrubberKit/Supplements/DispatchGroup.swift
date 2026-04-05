//
//  DispatchGroup.swift
//  ScrubberKit
//
//  Created by 秋星桥 on 2/18/25.
//

import Foundation

extension DispatchGroup {
    typealias LeaveHandler = @Sendable () -> Void
    typealias LeaveHandlerFunc = @Sendable (@escaping LeaveHandler) -> Void

    func enterBackground(_ leaveHandlerFunc: @escaping LeaveHandlerFunc) {
        enter()

        DispatchQueue.global().async {
            let hasLeft = LockedBox(false)

            leaveHandlerFunc {
                let shouldLeave = hasLeft.withLock { value in
                    guard !value else { return false }
                    value = true
                    return true
                }

                guard shouldLeave else {
                    assertionFailure()
                    return
                }

                self.leave()
            }
        }
    }
}
