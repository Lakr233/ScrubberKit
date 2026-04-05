import Foundation
@testable @preconcurrency import ScrubberKit
import Testing
import WebKit

struct ScrubWorkerCompatibilityTests {
    @MainActor
    private static var workers: [UUID: ScrubWorker] = [:]

    @Test("Navigation policy prefers universal-link suppression where supported")
    func preferredNavigationPolicy() {
        #if os(iOS) || os(visionOS) || targetEnvironment(macCatalyst)
            let expected = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow
            #expect(ScrubBrowserCompat.preferredNavigationPolicy().rawValue == expected.rawValue)
        #else
            #expect(ScrubBrowserCompat.preferredNavigationPolicy() == .allow)
        #endif
    }

    @Test("Popup routing stays in the current web view")
    func popupRouting() {
        #expect(ScrubBrowserCompat.shouldLoadPopupInCurrentWebView(targetFrameIsNil: true))
        #expect(!ScrubBrowserCompat.shouldLoadPopupInCurrentWebView(targetFrameIsNil: false))
    }

    @Test("JavaScript dialog defaults are headless-safe")
    func javaScriptDialogDefaults() {
        #expect(ScrubBrowserCompat.defaultJavaScriptConfirmResult == false)
        #expect(ScrubBrowserCompat.defaultJavaScriptPromptResult == nil)
    }

    @available(iOS 14.0, macOS 11.0, macCatalyst 14.0, visionOS 1.0, *)
    @MainActor
    @Test("Passkey interception installs both compatibility scripts")
    func installsPasskeyScripts() {
        let controller = WKUserContentController()
        let installed = ScrubBrowserCompat.installPasskeyInterceptIfSupported(on: controller)

        #expect(installed)
        #expect(controller.userScripts.count == 2)
        #expect(controller.userScripts.contains(where: { $0.source.contains("navigator.credentials") }))
        #expect(controller.userScripts.contains(where: { $0.source.contains(ScrubBrowserCompat.passkeyMessageHandler) }))
    }

    @available(iOS 14.0, macOS 11.0, macCatalyst 14.0, visionOS 1.0, *)
    @MainActor
    @Test("ScrubWorker handles popups, JS dialogs, and passkey rejection from local HTML")
    func integrationDataURLFlow() async {
        await compileAccessRules()

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<ScrubWorker.ScrubResult, Never>) in
            let popupHTML = """
            <!doctype html>
            <html>
            <body>
            <div id="popup-result">popup-loaded</div>
            <script>
            window.addEventListener('load', async function() {
                document.body.dataset.alert = 'before';
                alert('compat alert');
                document.body.dataset.alert = 'after';
                document.body.dataset.confirm = String(confirm('compat confirm'));
                document.body.dataset.prompt = String(prompt('compat prompt', 'default'));
                if (navigator.credentials && navigator.credentials.get) {
                    try {
                        await navigator.credentials.get({ publicKey: { challenge: new Uint8Array([1,2,3,4]), rpId: 'example.com', userVerification: 'preferred' } });
                        document.body.dataset.passkey = 'resolved';
                    } catch (error) {
                        document.body.dataset.passkey = error && error.name ? error.name : 'blocked';
                    }
                } else {
                    document.body.dataset.passkey = 'missing';
                }
            });
            </script>
            </body>
            </html>
            """

            let parentHTML = """
            <!doctype html>
            <html>
            <body>
            <script>
            window.addEventListener('load', function() {
                var popupHTML = \(javaScriptLiteral(popupHTML));
                var popupURL = 'data:text/html;charset=utf-8,' + encodeURIComponent(popupHTML);
                window.open(popupURL, '_blank');
            });
            </script>
            </body>
            </html>
            """

            let id = UUID()
            let worker = ScrubWorker(baseUrl: makeDataURL(parentHTML), softTimeout: 8) { result in
                Task { @MainActor in
                    Self.workers.removeValue(forKey: id)
                }
                continuation.resume(returning: result)
            }
            Self.workers[id] = worker
        }

        let scrubbed = result
        #expect(scrubbed.document.contains("popup-loaded"))
        #expect(scrubbed.document.contains("data-alert=\"after\""))
        #expect(scrubbed.document.contains("data-confirm=\"false\""))
        #expect(scrubbed.document.contains("data-prompt=\"null\""))
        #expect(scrubbed.document.contains("data-passkey="))
    }

    @MainActor
    private func compileAccessRules() async {
        await withCheckedContinuation { continuation in
            ScrubWorker.compileAccessRules {
                continuation.resume()
            }
        }
    }

    private func makeDataURL(_ html: String) -> URL {
        URL(string: "data:text/html;base64,\(Data(html.utf8).base64EncodedString())")!
    }

    private func javaScriptLiteral(_ string: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [string])
        let encoded = String(decoding: data, as: UTF8.self)
        return String(encoded.dropFirst().dropLast()).replacingOccurrences(of: "</", with: "<\\/")
    }
}
