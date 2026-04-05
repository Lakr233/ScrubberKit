import Foundation
@testable @preconcurrency import ScrubberKit
import Testing

@Test("Scrubber.document returns content for www.example.com")
func exampleDotCom() async throws {
    let url = try #require(URL(string: "https://www.example.com"))

    let document = await withCheckedContinuation { (continuation: CheckedContinuation<Scrubber.Document?, Never>) in
        DispatchQueue.main.async {
            Scrubber.document(for: url) { result in
                continuation.resume(returning: result)
            }
        }
    }

    let result = try #require(document)
    #expect(result.title.contains("Example Domain"))
    #expect(result.textDocument.contains("Example Domain"))
    #expect(result.markdownDocument.contains("Example Domain"))
}

@Test func search() async {
    await withCheckedContinuation { continuation in
        let scrubber = Scrubber(query: "Asspp")
        DispatchQueue.main.async {
            scrubber.run { result in
                #expect(!result.isEmpty)
                print("[*] searching \(scrubber.query) returns \(result.count) results")
                for doc in result {
                    print("[*] \(doc.title)")
                }
                continuation.resume()
            } onProgress: { progress in
                print("[*] \(progress)")
            }
        }
    }
}
