//
//  ViewModel.swift
//  Scrubber
//
//  Created by 秋星桥 on 2/18/25.
//

import Foundation
import ScrubberKit

class ViewModel: ObservableObject, Identifiable {
    let id: UUID = .init()

    init(
        query: String,
        enableURLsReranker: Bool = false,
        enableBM5Reranker: Bool = false,
        keepKPerHostname: Int? = nil
    ) {
        if enableURLsReranker {
            let urlsReranker = URLsReranker(
                question: enableBM5Reranker ? query : nil,
                keepKPerHostname: keepKPerHostname
            )
            core = .init(
                query: query,
                options: .init(urlsReranker: urlsReranker)
            )
        } else {
            core = .init(query: query)
        }

        core.run { document in
            self.documents = document
            self.saveToDownloads()
            self.processingText = String(localized: "\(document.count) document(s) has been saved to downloads.")
        } onProgress: { _ in
            self.onProgressUpdate()
        }
    }

    let core: Scrubber
    let date = Date()
    var query: String {
        core.query
    }

    @Published var documents: [Scrubber.Document]? {
        didSet { onProgressUpdate() }
    }

    @Published var searchingText: String = .init(localized: "Waiting for engine to load.")
    @Published var searchingProgress: Progress = .init()
    var searchingProgressText: String {
        "\(searchingProgress.completedUnitCount)/\(searchingProgress.totalUnitCount)"
    }

    @Published var searchingStatus: ProgressIndicator.Status = .pending

    @Published var fetchingText: String = .init(localized: "Waiting for content to be fetched.")
    @Published var fetchingProgress: Progress = .init()
    var fetchingProgressText: String {
        "\(fetchingProgress.completedUnitCount)/\(fetchingProgress.totalUnitCount)"
    }

    @Published var fetchingStatus: ProgressIndicator.Status = .pending

    @Published var processingText: String = .init(localized: "Waiting for content to be fetched.")
    @Published var processingProgress: Progress = .init()
    var processingProgressText: String {
        "\(processingProgress.completedUnitCount)/\(processingProgress.totalUnitCount)"
    }

    @Published var processingStatus: ProgressIndicator.Status = .pending

    var documentDirectory: URL {
        let dirName = "\(core.query) @\(Date().formatted())"
            .sanitizedFileName
        return FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent(dirName)
    }

    func onProgressUpdate() {
        let newSearchingProgress = Progress()
        newSearchingProgress.totalUnitCount = Int64(core.progress.engineStatus.count)
        newSearchingProgress.completedUnitCount = Int64(core.progress.engineStatusCompletedCount)
        searchingProgress = newSearchingProgress

        let websitesCount = core.progress.fetchedStatus.count
        if websitesCount > 0 {
            searchingText = String(localized: "Searched \(websitesCount) result(s).")
        }

        if searchingProgress.completedUnitCount == searchingProgress.totalUnitCount {
            if searchingProgress.totalUnitCount > 0 {
                searchingStatus = .success
            } else {
                searchingStatus = .failed
            }
        }

        if websitesCount > 0 {
            let newFetchingProgress = Progress()
            newFetchingProgress.totalUnitCount = Int64(websitesCount)
            newFetchingProgress.completedUnitCount = Int64(core.progress.fetchedStatusCompletedCount)
            fetchingProgress = newFetchingProgress
            if core.progress.fetchingStatusCount > 0 {
                fetchingText = String(localized: "Fetching \(core.progress.fetchingStatusCount) website(s).")
            } else {
                fetchingText = String(localized: "Fetched \(fetchingProgress.completedUnitCount) website(s).")
            }
            if fetchingProgress.completedUnitCount == fetchingProgress.totalUnitCount {
                fetchingStatus = .success
            } else if fetchingProgress.completedUnitCount > 0 {
                fetchingStatus = .working
            }
        }

        if let documents {
            let newProcessingProgress = Progress()
            let total = documents.count
            newProcessingProgress.totalUnitCount = Int64(total)
            newProcessingProgress.completedUnitCount = Int64(total)
            processingProgress = newProcessingProgress
            processingText = String(localized: "Processed \(processingProgress.completedUnitCount) of \(total) document(s).")
            processingStatus = .success
        }
    }

    func saveToDownloads() {
        guard let documents, !documents.isEmpty else {
            return
        }

        let baseDir = documentDirectory
        try! FileManager.default.createDirectory(
            at: baseDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        for document in documents {
            let fileName = document.title
                .sanitizedFileName
            let url = baseDir
                .appendingPathComponent(fileName)
                .appendingPathExtension("md")

            let text = document.markdownDocument
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
