import Foundation

enum AppConfig {
  // OpenClaw gateway (shared across all providers)
  static let openClawHost = Secrets.openClawHost
  static let openClawPort = Secrets.openClawPort
  static let openClawHookToken = Secrets.openClawHookToken
  static let openClawGatewayToken = Secrets.openClawGatewayToken
  static let openClawRelayURL = Secrets.openClawRelayURL

  static var isRelayConfigured: Bool {
    return !openClawRelayURL.isEmpty
      && openClawRelayURL != "https://openclaw.yourdomain.com"
  }

  private static var isLANConfigured: Bool {
    return openClawHost != "http://YOUR_MAC_HOSTNAME.local"
      && !openClawHost.isEmpty
  }

  static var isOpenClawConfigured: Bool {
    let hasToken = openClawGatewayToken != "YOUR_OPENCLAW_GATEWAY_TOKEN"
      && !openClawGatewayToken.isEmpty
    return hasToken && (isRelayConfigured || isLANConfigured)
  }

  /// Returns the relay URL if configured, otherwise builds from LAN host:port.
  static var openClawBaseURL: String {
    if isRelayConfigured {
      return openClawRelayURL
    }
    return "\(openClawHost):\(openClawPort)"
  }

  // Video settings (shared across all providers)
  static let videoFrameInterval: TimeInterval = 1.0
  static let videoJPEGQuality: CGFloat = 0.5
}
