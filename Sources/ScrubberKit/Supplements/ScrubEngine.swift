//
//  ScrubEngine.swift
//  Dealer
//
//  Created by 秋星桥 on 2/9/25.
//

import Foundation
import SwiftSoup

public enum ScrubEngine: String, CaseIterable, Codable, Sendable {
    case google
    case duckduckgo
    case yahoo
    case bing

    var template: String {
        switch self {
        case .google:
            "https://www.google.com/search?q=%@"
        case .bing:
            "https://www.bing.com/search?q=%@"
        case .duckduckgo:
            "https://www.duckduckgo.com/?q=%@"
        case .yahoo:
            "https://search.yahoo.com/search?q=%@"
        }
    }

    func makeSearchQueryRequest(_ keyword: String) -> URL? {
        let encoder = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        let text = String(format: template, encoder ?? "")
        guard let url = URL(string: text) else {
            return nil
        }
        return url
    }

    private func parse(body: Element) -> [String] {
        assert(!Thread.isMainThread)

        var ans: [String] = []
        switch self {
        case .google:
            try? body.select("#rso").forEach { object in
                for objectDiv in object.children() {
                    let linkText = try? objectDiv.select("[href]").array().first?.attr("href")
                    if let link = linkText, !link.isEmpty {
                        ans.append(link)
                    }
                }
            }
            return ans
        case .duckduckgo:
            try? body.select(".react-results--main").forEach { object in
                for listElement in object.children() {
                    let linkText = try? listElement
                        .select("[data-testid=result-title-a]")
                        .array()
                        .first?
                        .attr("href")
                    if let link = linkText, !link.isEmpty {
                        ans.append(link)
                    }
                }
            }
            return ans
        case .yahoo:
            try? body.select("#main-algo").forEach { object in
                try? object.select(".title").forEach { element in
                    let linkText = try? element.select("[href]").array().first?.attr("href")
                    if let link = linkText, !link.isEmpty {
                        ans.append(link)
                    }
                }
            }
            return ans
        case .bing:
            try? body.select("ol#b_results li.b_algo").forEach { algo in
                if let firstLink = try? algo.select("div.b_tpcn a[href]").first() {
                    if let linkElement = try? algo.select("div.b_algoheader a[href]").first() {
                        if let link = try? linkElement.attr("href"), !link.isEmpty {
                            ans.append(link)
                        }
                    } else if let link = try? firstLink.attr("href"), !link.isEmpty {
                        ans.append(link)
                    }
                }
            }
            return ans
        }
    }

    func parseSearchResult(_ html: String) -> [URL] {
        assert(!Thread.isMainThread)

        guard let soup = try? SwiftSoup.parse(html) else { return [] }
        guard let body = soup.body() else { return [] }

        var preflightAnwser: [String] = parse(body: body)
        if preflightAnwser.isEmpty {
            let fallback = try? body
                .select("a[href]")
                .array()
                .compactMap { try? $0.attr("href") }
            preflightAnwser = fallback ?? []
        }

        var possibleLinks: [String] = preflightAnwser
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !$0.starts(with: "/") }
            .filter { !$0.starts(with: "#") }

        let searchContent = possibleLinks
        possibleLinks = possibleLinks
            .filter { candidate in
                // remove url that contains another url linking to it
                // https://translate.google.com/translate?u= (that link)
                !searchContent.contains { matchShorter in
                    candidate.contains(matchShorter) && candidate != matchShorter
                }
            }
            .filter { candidate in
                // remove url that lowercase is already in the list
                !possibleLinks.contains { matchLower in
                    candidate.lowercased() == matchLower.lowercased() && candidate != matchLower
                }
            }

        possibleLinks = .init(Set(possibleLinks)).sorted()

        return possibleLinks
            .compactMap { URL(string: $0) }
            .filter { $0.scheme == "http" || $0.scheme == "https" }
            .filter { !($0.host?.isEmpty ?? true) }
    }

    private func parse(body: Element) -> [SearchSnippet] {
        assert(!Thread.isMainThread)

        var snippets: [SearchSnippet] = []
        switch self {
        case .google:
            try? body.select("#rso").forEach { object in
                let elements = object.children()

                for element in elements {
                    let link = extractLink(
                        try? element.select("[href]").array().first
                    )

                    guard let link else {
                        return
                    }

                    let title = try? element.select("h3").first()?.text()

                    let description = try?
                        (element.select("div.VwiC3b").first()
                            ?? element.select("span.st").first())?.text()

                    snippets.append(
                        .init(
                            engine: self,
                            url: link,
                            title: title,
                            description: description
                        )
                    )
                }
            }
        case .duckduckgo:
            try? body.select(".react-results--main").forEach { object in
                for listElement in object.children() {
                    let link = extractLink(
                        try? listElement.select(
                            "[data-testid=result-title-a]"
                        ).first
                    )

                    guard let link else {
                        continue
                    }

                    let title = try? listElement.select(
                        "[data-testid=result-title-a] span"
                    ).first()?.text()

                    let description = try? listElement.select(
                        "[data-result=snippet"
                    ).first()?.text()

                    snippets.append(
                        .init(
                            engine: self,
                            url: link,
                            title: title,
                            description: description
                        )
                    )
                }
            }
        case .yahoo:
            try? body.select("#main-algo").forEach { object in
                try? object.select("section.algo").forEach { section in
                    let link = extractLink(
                        try? section.select(".title [href]").array().first
                    )

                    guard let link else {
                        return
                    }

                    let title = try? section.select(".title a.s-title").first()?
                        .text()

                    let description = try? section.select("p.s-desc").first()?
                        .text()

                    snippets.append(
                        .init(
                            engine: self,
                            url: link,
                            title: title,
                            description: description
                        )
                    )
                }
            }
        case .bing:
            try? body.select("ol#b_results li.b_algo").forEach { algo in
                let link = extractLink(
                    try? algo.select("div.b_algoheader a[href]").first()
                )

                guard let link else {
                    return
                }

                let title = try? algo.select("div.b_algoheader a h2").first()?
                    .text()

                let description = try? algo.select(".b_caption p").first()?
                    .text()

                snippets.append(
                    .init(
                        engine: self,
                        url: link,
                        title: title,
                        description: description
                    )
                )
            }
        }

        return snippets
    }

    private func extractLink(_ element: Element?) -> URL? {
        guard let linkText = try? element?.attr("href") else {
            return nil
        }

        let link = linkText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            !link.isEmpty && !link.starts(with: "/") && !link.starts(with: "#")
        else {
            return nil
        }

        let url = URL(string: link)

        guard url?.scheme == "http" || url?.scheme == "https" else {
            return nil
        }

        guard url?.host?.isEmpty == false else {
            return nil
        }

        return url
    }

    func parseSearchSnippet(_ html: String) -> [SearchSnippet] {
        assert(!Thread.isMainThread)

        guard let soup = try? SwiftSoup.parse(html) else { return [] }
        guard let body = soup.body() else { return [] }

        var snippets: [SearchSnippet] = parse(body: body)
        if snippets.isEmpty {
            try? body.select("a[href]").array().forEach { element in
                let link = extractLink(element)

                guard let link else {
                    return
                }

                let title = try? element.text()

                snippets.append(
                    .init(
                        engine: self,
                        url: link,
                        title: title
                    )
                )
            }
        }

        let searchContent = snippets.map(\.url.absoluteString)

        snippets = snippets.filter { snippet in
            !searchContent.contains { match in
                snippet.url.absoluteString.contains(match)
                    && snippet.url.absoluteString != match
            }
        }.filter { snippet in
            !snippets.contains { match in
                snippet.url.absoluteString.lowercased()
                    == match.url.absoluteString.lowercased()
                    && snippet.url.absoluteString != match.url.absoluteString
            }
        }

        return snippets
    }
}
