//
//  URLsReranker.swift
//  ScrubberKit
//
//  Created by John Mai on 2025/3/14.
//

import Foundation

public final class URLsReranker: @unchecked Sendable {
    let freqFactor: Double
    let hostnameBoostFactor: Double
    let pathBoostFactor: Double
    let decayFactor: Double
    let bm25RerankFactor: Double
    let minBoost: Double
    let maxBoost: Double
    let question: String?
    let keepKPerHostname: Int?

    public init(
        freqFactor: Double = 0.5,
        hostnameBoostFactor: Double = 0.5,
        pathBoostFactor: Double = 0.4,
        decayFactor: Double = 0.8,
        bm25RerankFactor: Double = 0.8,
        minBoost: Double = 0,
        maxBoost: Double = 5,
        question: String? = nil,
        keepKPerHostname: Int? = nil
    ) {
        self.freqFactor = freqFactor
        self.hostnameBoostFactor = hostnameBoostFactor
        self.pathBoostFactor = pathBoostFactor
        self.decayFactor = decayFactor
        self.bm25RerankFactor = bm25RerankFactor
        self.minBoost = minBoost
        self.maxBoost = maxBoost
        self.question = question
        self.keepKPerHostname = keepKPerHostname
    }

    private func normalizeCount(_ count: Double, _ total: Double) -> Double {
        total > 0 ? count / total : 0
    }

    private func extractUrlParts(_ url: URL) -> (
        hostname: String, path: String
    ) {
        (hostname: url.host ?? "", path: url.path)
    }

    private func countUrlParts(urls: [URL]) -> (
        hostnameCount: [String: Int],
        pathPrefixCount: [String: Int],
        totalUrls: Double
    ) {
        var hostnameCount: [String: Int] = [:]
        var pathPrefixCount: [String: Int] = [:]
        var totalUrls = 0

        for item in urls {
            totalUrls += 1
            let hostname = item.host ?? ""
            let path = item.path

            hostnameCount[hostname] =
                (hostnameCount[hostname] ?? 0) + 1

            let pathSegments = path.split(separator: "/").filter {
                !$0.isEmpty
            }.map { String($0) }
            for (index, _) in pathSegments.enumerated() {
                let prefix =
                    "/" + pathSegments[0 ... index].joined(separator: "/")
                pathPrefixCount[prefix] = (pathPrefixCount[prefix] ?? 0) + 1
            }
        }

        return (hostnameCount, pathPrefixCount, Double(totalUrls))
    }

    private func smartMergeStrings(str1: String?, str2: String?) -> String {
        guard let str1 else { return str2 ?? "" }
        guard let str2 else { return str1 }

        if str1.contains(str2) { return str1 }
        if str2.contains(str1) { return str2 }

        let maxOverlap = min(str1.count, str2.count)
        var bestOverlapLength = 0

        var overlapLength = maxOverlap
        while overlapLength > 0 {
            let endOfStr1 = str1.suffix(overlapLength)
            let startOfStr2 = str2.prefix(overlapLength)

            if endOfStr1 == startOfStr2 {
                bestOverlapLength = overlapLength
                break
            }
            overlapLength -= 1
        }

        if bestOverlapLength > 0 {
            let newStr = str1.prefix(str1.count - bestOverlapLength) + str2
            return String(newStr)
        } else {
            return str1 + str2
        }
    }

    public func ranking(_ snippets: [SearchSnippet]) -> [BoostedSearchSnippet] {
        let urls = snippets.compactMap(\.url)
        guard !urls.isEmpty else { return [] }

        let (hostnameCount, pathPrefixCount, totalUrls) = countUrlParts(
            urls: urls
        )

        var bm25Scores: [String: Double] = [:]
        if let question {
            let bm25 = BM25Okapi()
            let documents = snippets.map {
                smartMergeStrings(str1: $0.title, str2: $0.description)
            }
            bm25.fit(documents)
            let results = bm25.search(query: question)
            let normalized = bm25.normalize(scores: results)

            for (i, snippet) in snippets.enumerated() {
                bm25Scores[snippet.url.absoluteString] = normalized[i]
            }
        }

        var boostedSnippets: [BoostedSearchSnippet] = snippets.map { snippet in
            let hostname = snippet.url.host ?? ""
            let path = snippet.url.path

            let hostnameFreq = normalizeCount(
                Double(hostnameCount[hostname] ?? 0), totalUrls
            )

            let hostnameBoost = hostnameFreq * self.hostnameBoostFactor

            let pathBoost = calculatePathBoost(
                path: path, pathPrefixCount: pathPrefixCount,
                totalUrls: totalUrls
            )

            let freqBoost =
                (snippet.weight ?? 0) / totalUrls * self.freqFactor

            let bm25RerankBoost = bm25Scores[snippet.url.absoluteString] ?? 0

            let finalScore = min(
                max(hostnameBoost + pathBoost + freqBoost + bm25RerankBoost, self.minBoost),
                self.maxBoost
            )

            return BoostedSearchSnippet(
                from: snippet,
                freqBoost: freqBoost,
                hostnameBoost: hostnameBoost,
                pathBoost: pathBoost,
                bm25RerankBoost: bm25RerankBoost,
                finalScore: finalScore
            )
        }

        boostedSnippets = boostedSnippets.sorted {
            $0.finalScore > $1.finalScore
        }

        if let keepKPerHostname {
            boostedSnippets = filterByHostname(
                snippets: boostedSnippets, keepKPerHostname: keepKPerHostname
            )
        }

        return boostedSnippets
    }

    private func filterByHostname(
        snippets: [BoostedSearchSnippet], keepKPerHostname: Int
    ) -> [BoostedSearchSnippet] {
        var result = [BoostedSearchSnippet]()
        var hostnameCounter = [String: Int]()

        let sortedSnippets = snippets.sorted { $0.finalScore > $1.finalScore }

        for snippet in sortedSnippets {
            let hostname = snippet.url.host ?? ""
            if (hostnameCounter[hostname] ?? 0) < keepKPerHostname {
                result.append(snippet)
                hostnameCounter[hostname, default: 0] += 1
            }
        }

        return result
    }

    private func calculatePathBoost(
        path: String, pathPrefixCount: [String: Int], totalUrls: Double
    ) -> Double {
        let pathSegments = path.split(separator: "/").filter { !$0.isEmpty }
            .map(String.init)
        var totalBoost = 0.0

        for i in 0 ..< pathSegments.count {
            let prefix = "/" + pathSegments[0 ... i].joined(separator: "/")
            let prefixFreq = Double(pathPrefixCount[prefix] ?? 0) / totalUrls
            let decayedBoost =
                prefixFreq * pow(decayFactor, Double(i))
                    * pathBoostFactor
            totalBoost += decayedBoost
        }

        return totalBoost
    }
}

public struct SearchSnippet: Sendable {
    public let engine: ScrubEngine
    public let url: URL
    public let title: String?
    public let description: String?
    public let weight: Double?

    public init(
        engine: ScrubEngine,
        url: URL,
        title: String?,
        description: String? = nil,
        weight: Double? = nil
    ) {
        self.engine = engine
        self.url = url
        self.title = title
        self.description = description
        self.weight = weight
    }
}

public struct BoostedSearchSnippet: Equatable, Sendable {
    public let engine: ScrubEngine
    public let url: URL
    public let title: String?
    public let description: String?
    public let weight: Double?
    public let freqBoost: Double
    public let hostnameBoost: Double
    public let pathBoost: Double
    public let bm25RerankBoost: Double
    public let finalScore: Double

    public init(
        from snippet: SearchSnippet,
        freqBoost: Double,
        hostnameBoost: Double,
        pathBoost: Double,
        bm25RerankBoost: Double = 0,
        finalScore: Double
    ) {
        engine = snippet.engine
        url = snippet.url
        title = snippet.title
        description = snippet.description
        weight = snippet.weight
        self.freqBoost = freqBoost
        self.hostnameBoost = hostnameBoost
        self.pathBoost = pathBoost
        self.bm25RerankBoost = bm25RerankBoost
        self.finalScore = finalScore
    }
}

public struct RankOptions: Sendable {
    let freqFactor: Double
    let hostnameBoostFactor: Double
    let pathBoostFactor: Double
    let decayFactor: Double
    let bm25RerankFactor: Double
    let minBoost: Double
    let maxBoost: Double
    let question: String?
    let keepKPerHostname: Int?

    public init(
        freqFactor: Double = 0.5,
        hostnameBoostFactor: Double = 0.5,
        pathBoostFactor: Double = 0.4,
        decayFactor: Double = 0.8,
        bm25RerankFactor: Double = 0.8,
        minBoost: Double = 0,
        maxBoost: Double = 5,
        question: String? = nil,
        keepKPerHostname: Int? = nil
    ) {
        self.freqFactor = freqFactor
        self.hostnameBoostFactor = hostnameBoostFactor
        self.pathBoostFactor = pathBoostFactor
        self.decayFactor = decayFactor
        self.bm25RerankFactor = bm25RerankFactor
        self.minBoost = minBoost
        self.maxBoost = maxBoost
        self.question = question
        self.keepKPerHostname = keepKPerHostname
    }
}
