//
//  Scrubber+Document.swift
//  Playground
//
//  Created by 秋星桥 on 2/17/25.
//

import Foundation
import SwiftSoup

extension Scrubber {
    public struct Document: Sendable {
        public let title: String
        public let url: URL
        public let document: String
        public let textDocument: String
        public let markdownDocument: String
        public let engine: ScrubEngine?
    }

    static func finalize(document: String, markdownDocument: String, engine: ScrubEngine? = nil, url: URL) -> Document? {
        assert(!Thread.isMainThread)
        guard let soup = try? SwiftSoup.parse(document) else {
            return nil
        }

        var title = (try? soup.title()) ?? ""
        if title.isEmpty { title = url.host ?? "" }
        if title.isEmpty { return nil }

        guard let textDocument = try? soup.text() else {
            return nil
        }

        guard !textDocument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var newURL = url
        if let text = url.absoluteString.removingPercentEncoding,
           let build = URL(string: text)
        { newURL = build }

        print("[*] result on \(newURL.absoluteString) \(title)")

        return .init(
            title: title,
            url: newURL,
            document: document,
            textDocument: textDocument,
            markdownDocument: markdownDocument,
            engine: engine
        )
    }
}
