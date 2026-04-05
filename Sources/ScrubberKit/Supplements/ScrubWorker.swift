//
//  ScrubWorker.swift
//  AppleQuery
//
//  Created by QAQ on 2023/8/23.
//

@preconcurrency import WebKit

private let accessControlSourceCode = ###"""
[
  {
    "trigger": {
      "url-filter": ".*",
      "resource-type": ["style-sheet"]
    },
    "action": {
      "type": "block"
    }
  },
  {
    "trigger": {
      "url-filter": ".*",
      "resource-type": ["font"]
    },
    "action": {
      "type": "block"
    }
  },
  {
    "trigger": {
      "url-filter": ".*",
      "resource-type": ["image"]
    },
    "action": {
      "type": "block"
    }
  },
  {
    "trigger": {
      "url-filter": ".*",
      "resource-type": ["media"]
    },
    "action": {
      "type": "block"
    }
  }
]
"""###
@MainActor
private var accessControlRule: WKContentRuleList?

enum ScrubBrowserCompat {
    static let passkeyMessageHandler = "scrubberPasskeyInterceptHandler"

    static func preferredNavigationPolicy() -> WKNavigationActionPolicy {
        #if os(iOS) || os(visionOS) || targetEnvironment(macCatalyst)
            if let policy = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) {
                return policy
            }
        #endif
        return .allow
    }

    static func shouldLoadPopupInCurrentWebView(targetFrameIsNil: Bool) -> Bool {
        targetFrameIsNil
    }

    static var defaultJavaScriptConfirmResult: Bool {
        false
    }

    static var defaultJavaScriptPromptResult: String? {
        nil
    }

    @discardableResult
    @MainActor
    static func installPasskeyInterceptIfSupported(on controller: WKUserContentController) -> Bool {
        guard #available(iOS 14.0, macOS 11.0, macCatalyst 14.0, visionOS 1.0, *) else {
            return false
        }

        controller.addUserScript(
            WKUserScript(
                source: passkeyPageScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .page
            )
        )
        controller.addUserScript(
            WKUserScript(
                source: passkeyRelayScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .defaultClient
            )
        )
        return true
    }

    @MainActor
    static func attachPasskeyMessageHandler(
        _ handler: WKScriptMessageHandler,
        to controller: WKUserContentController
    ) {
        guard #available(iOS 14.0, macOS 11.0, macCatalyst 14.0, visionOS 1.0, *) else {
            return
        }
        controller.add(handler, contentWorld: .defaultClient, name: passkeyMessageHandler)
    }

    @MainActor
    static func removePasskeyMessageHandler(from controller: WKUserContentController) {
        if #available(iOS 14.0, macOS 11.0, macCatalyst 14.0, visionOS 1.0, *) {
            controller.removeScriptMessageHandler(forName: passkeyMessageHandler, contentWorld: .defaultClient)
        } else {
            controller.removeScriptMessageHandler(forName: passkeyMessageHandler)
        }
    }

    static let passkeyPageScript = """
    (function() {
        if (navigator.credentials) {
            var origCreate = navigator.credentials.create.bind(navigator.credentials);
            var origGet = navigator.credentials.get.bind(navigator.credentials);

            navigator.credentials.create = function(options) {
                if (options && options.publicKey) {
                    document.documentElement.setAttribute('data-sk-pk', Date.now().toString());
                    return Promise.reject(new DOMException("Passkey is not supported in this browser.", "NotAllowedError"));
                }
                return origCreate.apply(navigator.credentials, arguments);
            };

            navigator.credentials.get = function(options) {
                if (options && options.publicKey) {
                    document.documentElement.setAttribute('data-sk-pk', Date.now().toString());
                    return Promise.reject(new DOMException("Passkey is not supported in this browser.", "NotAllowedError"));
                }
                return origGet.apply(navigator.credentials, arguments);
            };
        }
    })();
    """

    static let passkeyRelayScript = """
    (function() {
        function relay() {
            if (document.documentElement.hasAttribute('data-sk-pk')) {
                window.webkit.messageHandlers.\(passkeyMessageHandler).postMessage('detected');
                document.documentElement.removeAttribute('data-sk-pk');
            }
        }
        var observer = new MutationObserver(function() { relay(); });
        observer.observe(document.documentElement, { attributes: true, attributeFilter: ['data-sk-pk'] });
        relay();
    })();
    """
}

@MainActor
class ScrubWorker: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private let web = WebView()
    private let baseUrl: URL

    struct ScrubResult {
        let url: URL
        let document: String
        let markdownDocument: String
    }

    private var completion: (@Sendable (ScrubResult) -> Void)?
    private var didCleanup = false

    init(baseUrl: URL, softTimeout: TimeInterval = 15, completion: @escaping @Sendable (ScrubResult) -> Void) {
        self.baseUrl = baseUrl
        self.completion = completion

        super.init()

        web.uiDelegate = self
        web.navigationDelegate = self
        ScrubBrowserCompat.attachPasskeyMessageHandler(self, to: web.configuration.userContentController)
        let request = URLRequest(
            url: baseUrl,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: softTimeout
        )
        web.load(request)

        scheduleContentReporter(delay: softTimeout)
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        web.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight)") { _, _ in
        }
        scheduleContentReporter(delay: 3) // in case of another navigation fired by js
    }

    var navigationLimit = 4

    func webView(
        _: WKWebView,
        decidePolicyFor _: WKNavigationAction,
        preferences _: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        guard navigationLimit > 0 else {
            decisionHandler(.cancel, .init())
            scheduleContentReporter(delay: 0)
            return
        }
        navigationLimit -= 1
        scheduleContentReporter(delay: 5)
        decisionHandler(ScrubBrowserCompat.preferredNavigationPolicy(), .init())
    }

    func cancel() {
        if Thread.isMainThread {
            performCompletion()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.performCompletion()
            }
        }
    }

    func scheduleContentReporter(delay: Double) {
        assert(Thread.isMainThread)
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(performCompletion),
            object: nil
        )
        perform(#selector(performCompletion), with: nil, afterDelay: delay)
    }

    @objc
    private func performCompletion() {
        guard let completion else { return }
        cleanupCompatibilityState()
        self.completion = nil

        let web = web

        web.evaluateJavaScript("document.documentElement.outerHTML") { data, _ in
            web.captureMarkdownContent { markdown in
                completion(.init(
                    url: self.web.url ?? self.baseUrl,
                    document: data as? String ?? "",
                    markdownDocument: markdown
                ))
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith _: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        guard ScrubBrowserCompat.shouldLoadPopupInCurrentWebView(targetFrameIsNil: navigationAction.targetFrame == nil) else {
            return nil
        }

        webView.load(navigationAction.request)
        return nil
    }

    func webView(
        _: WKWebView,
        runJavaScriptAlertPanelWithMessage _: String,
        initiatedByFrame _: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        completionHandler()
    }

    func webView(
        _: WKWebView,
        runJavaScriptConfirmPanelWithMessage _: String,
        initiatedByFrame _: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        completionHandler(ScrubBrowserCompat.defaultJavaScriptConfirmResult)
    }

    func webView(
        _: WKWebView,
        runJavaScriptTextInputPanelWithPrompt _: String,
        defaultText _: String?,
        initiatedByFrame _: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        completionHandler(ScrubBrowserCompat.defaultJavaScriptPromptResult)
    }

    func userContentController(_: WKUserContentController, didReceive _: WKScriptMessage) {
        scheduleContentReporter(delay: 1)
    }

    private func cleanupCompatibilityState() {
        guard !didCleanup else { return }
        didCleanup = true
        ScrubBrowserCompat.removePasskeyMessageHandler(from: web.configuration.userContentController)
    }
}

private extension ScrubWorker {
    class WebView: WKWebView {
        init() {
            let config = WKWebViewConfiguration()
            #if os(iOS)
                config.allowsInlineMediaPlayback = false
                config.allowsPictureInPictureMediaPlayback = false
                config.dataDetectorTypes = []
            #endif
            config.allowsAirPlayForMediaPlayback = false
            config.mediaTypesRequiringUserActionForPlayback = .all
            config.preferences.javaScriptCanOpenWindowsAutomatically = true
            config.applicationNameForUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
            config.websiteDataStore = .nonPersistent()
            if #available(iOS 17.0, macOS 14.0, *) {
                config.allowsInlinePredictions = false
            }
            if let accessControlRule {
                config.userContentController.add(accessControlRule)
            } else {
                ScrubWorker.compileAccessRules()
            }
            for script in Turndown.setupScripts {
                config.userContentController.addUserScript(script)
            }
            _ = ScrubBrowserCompat.installPasskeyInterceptIfSupported(on: config.userContentController)
            super.init(
                frame: .init(x: 0, y: 0, width: 800, height: 3200),
                configuration: config
            )
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError()
        }
    }
}

extension ScrubWorker {
    @MainActor
    static func compileAccessRules(completion: (() -> Void)? = nil) {
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "PlainTextAccessControlRule",
            encodedContentRuleList: accessControlSourceCode
        ) { list, _ in
            accessControlRule = list
            completion?()
        }
    }
}
