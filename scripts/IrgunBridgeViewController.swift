import Capacitor
import WebKit

// Configure WKWebView *before construction*. Changes made to an already
// initialized WKWebViewConfiguration in AppDelegate are not applied to the
// underlying media pipeline. iPhone and iPad must use the same PiP policy.
final class IrgunBridgeViewController: CAPBridgeViewController {
    override func webViewConfiguration(for instanceConfiguration: InstanceConfiguration) -> WKWebViewConfiguration {
        let configuration = super.webViewConfiguration(for: instanceConfiguration)
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        return configuration
    }
}
