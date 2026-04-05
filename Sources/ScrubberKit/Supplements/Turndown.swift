//
//  Turndown.swift
//  ScrubberKit
//
//  Created by qaq on 7/11/2025.
//

import Foundation
import OSLog
import WebKit

@available(iOS 14.0, macOS 11.0, *)
let logger = Logger(subsystem: "Turndown", category: "Backend")

public enum Turndown {
    @MainActor
    public static let setupScripts: [WKUserScript] = [
        "turndown",
        "turndown-webkit-lite",
    ].map { input in
        .init(
            source: {
                let url = Bundle.module.url(forResource: input, withExtension: "js")!
                return try! String(contentsOf: url, encoding: .utf8)
            }(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }
}

public extension WKWebView {
    @MainActor
    func captureMarkdownContent(_ completion: @escaping (String) -> Void) {
        let script = """
        window.parseWithTurndown();
        """
        evaluateJavaScript(script) { data, error in
            if let error {
                if #available(iOS 14.0, macOS 11.0, *) {
                    logger.error("\(error.localizedDescription)")
                }
                completion("")
            } else {
                let document = data as? String ?? ""
                print(document)
                completion(document)
            }
        }
    }
}
