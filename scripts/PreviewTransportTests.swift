import Foundation

@main
struct PreviewTransportTests {
    static func main() {
        let signedPath = "/objects/a%2Fb/image.jpg?token=a%2Bb%2Fc%3D&name=%E5%9B%BE%20%E7%89%87.jpg&empty="
        let secure = "https://dl-z01a-0042.mypikpak.com" + signedPath
        precondition(PreviewTransport.secureContentURL("http://dl-z01a-0042.mypikpak.com" + signedPath)?.absoluteString == secure,
                     "PikPak's HTTP original links must use HTTPS without changing signed path/query bytes")
        precondition(PreviewTransport.secureContentURL(secure)?.absoluteString == secure,
                     "Existing signed HTTPS URLs must remain byte-for-byte unchanged")
        precondition(PreviewTransport.secureContentURL(" \nHTTPS://example.test/image.jpg\t")?.absoluteString == "https://example.test/image.jpg")
        precondition(PreviewTransport.secureContentURL("http://dl-z01a-0042.mypikpak.com:80" + signedPath)?.absoluteString == secure,
                     "An explicit HTTP default port must not force TLS onto port 80")
        for invalid in [
            "", "not a URL", "https:/missing-host", "https:///missing-host",
            "file:///tmp/preview.jpg", "//dl-z01a-0042.mypikpak.com/image.jpg",
            "http://example.test/image.jpg", "http://mypikpak.com/image.jpg",
            "http://dl-z01a-0042.mypikpak.com.example.test/image.jpg",
            "http://dl-z01a-0042.mypikpak.com@evil.test/image.jpg",
            "http://user:password@dl-z01a-0042.mypikpak.com/image.jpg",
            "http://dl-z01a-0042.mypikpak.com:8080/image.jpg",
        ] {
            precondition(PreviewTransport.secureContentURL(invalid) == nil,
                         "Unusable URLs and unrelated HTTP hosts must remain rejected")
        }
        print("PASS: PikPak CDN HTTPS promotion, unchanged signatures, existing HTTPS links, invalid/untrusted URL rejection")

        // This standalone test process can safely simulate a Terminal launch
        // without changing the app, shell or macOS network preferences.
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
            setenv(key, "http://127.0.0.1:9", 1)
        }
        precondition(PreviewTransport.effectiveProxyURL(" \n ").isEmpty,
                     "An empty app setting must not inherit a shell proxy")
        precondition(!PreviewTransport.usesProxy(""), "The route indicator must report direct")
        let direct = PreviewTransport.configuration(proxyURL: "")
        precondition(direct.connectionProxyDictionary?.isEmpty == true,
                     "A nil dictionary would inherit the system proxy/PAC settings")
        let session = URLSession(configuration: direct)
        precondition(session.configuration.connectionProxyDictionary?.isEmpty == true,
                     "The created session must retain the direct route")
        session.invalidateAndCancel()

        let explicit = PreviewTransport.configuration(proxyURL: " http://127.0.0.1:7890 \n")
        precondition(PreviewTransport.usesProxy("http://127.0.0.1:7890"),
                     "A deliberate app override remains available")
        precondition(explicit.connectionProxyDictionary?["HTTPSProxy"] as? String == "127.0.0.1"
                     && explicit.connectionProxyDictionary?["HTTPSPort"] as? Int == 7890)
        precondition(PreviewTransport.configuration(proxyURL: "invalid://host")
            .connectionProxyDictionary?.isEmpty == true, "Invalid overrides must stay direct")
        print("Preview transport: 7 checks passed (inherited proxies disabled, explicit override retained)")
    }
}
