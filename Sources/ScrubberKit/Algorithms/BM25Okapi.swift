//
//  BM25Okapi.swift
//  ScrubberKit
//
//  Created by John Mai on 2025/3/15.
//

import Foundation
import NaturalLanguage

class BM25Okapi {
    private let k1: Double
    private let b: Double

    private var corpus: [[String]] = []
    private var docFrequency: [String: Int] = [:]
    private var docLengths: [Int] = []
    private var averageDocLength: Double = 0
    private var totalDocs: Int = 0

    init(k1: Double = 1.5, b: Double = 0.75) {
        self.k1 = k1
        self.b = b
    }

    func fit(_ documents: [String]) {
        corpus = []
        docFrequency = [:]
        docLengths = []

        for document in documents {
            let tokens = tokenize(document)
            corpus.append(tokens)

            let docLength = tokens.count
            docLengths.append(docLength)

            var seenTokens = Set<String>()
            for token in tokens {
                if !seenTokens.contains(token) {
                    docFrequency[token, default: 0] += 1
                    seenTokens.insert(token)
                }
            }
        }

        totalDocs = documents.count
        averageDocLength =
            docLengths.isEmpty
                ? 0 : Double(docLengths.reduce(0, +)) / Double(docLengths.count)
    }

    func search(query: String) -> [(index: Int, score: Double)] {
        let queryTokens = tokenize(query)
        var scores: [Double] = Array(repeating: 0, count: corpus.count)

        for (docIndex, document) in corpus.enumerated() {
            var score: Double = 0

            for token in queryTokens {
                guard let df = docFrequency[token], df > 0 else { continue }

                let idf = calculateIDF(token: token)

                let tf = document.count(where: { $0 == token })

                let docLength = Double(docLengths[docIndex])
                let numerator = Double(tf) * (k1 + 1)
                let denominator =
                    Double(tf) + k1 * (1 - b + b * docLength / averageDocLength)
                let termScore = idf * numerator / denominator

                score += termScore
            }

            scores[docIndex] = score
        }

        return scores.enumerated()
            .map { (index: $0, score: $1) }
            .sorted { $0.score > $1.score }
    }

    func calculateIDF(token: String) -> Double {
        let n = docFrequency[token] ?? 0
        return log(
            (Double(totalDocs) - Double(n) + 0.5) / (Double(n) + 0.5) + 1
        )
    }

    func tokenize(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var keyWords: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex ..< text.endIndex) {
            tokenRange, _ in
            keyWords.append(String(text[tokenRange]))
            return true
        }
        return keyWords
    }

    func normalize(scores: [(index: Int, score: Double)]) -> [Int: Double] {
        let sumScores = scores.reduce(0.0) { $0 + $1.score }

        if sumScores == 0 {
            return Dictionary(uniqueKeysWithValues: scores.map { ($0.index, 0.0) })
        }

        return Dictionary(uniqueKeysWithValues: scores.map { ($0.index, $0.score / sumScores) })
    }
}
