import Cocoa

class InspectorSummaryCellView: NSTableCellView {
  /// The stack view laying out all of the views.
  @IBOutlet var stackView: NSStackView!

  /// The primary summary content of the log message.
  ///
  /// Only present for HTTP requests.
  @IBOutlet var primaryTextField: NSTextField!

  /// The Discord gateway event for this log message.
  ///
  /// Not present in HTTP requests.
  @IBOutlet var eventTextField: NSTextField!

  /// An image view indicating the origin and or destination of the packet
  /// (HTTP or gateway).
  @IBOutlet var packetOriginImageView: NSImageView!

  func setup(logMessage: LogMessage) {
    let font = NSFont.preferredFont(forTextStyle: .body)
    primaryTextField.font = .monospacedSystemFont(ofSize: font.pointSize, weight: .regular)

    switch logMessage.variant {
    case .gateway(let gatewayPacket):
      packetOriginImageView.image = NSImage(systemSymbolName: "bolt.horizontal.fill", accessibilityDescription: "Gateway")
      eventTextField.stringValue = String(describing: gatewayPacket.packet.op)
      if gatewayPacket.packet.op == .dispatch {
        eventTextField.textColor = .secondaryLabelColor
        primaryTextField.stringValue = gatewayPacket.packet.eventName ?? "(UNKNOWN))"
      } else {
        primaryTextField.isHidden = true
      }
    case .http(let log):
      packetOriginImageView.image = NSImage(systemSymbolName: "envelope.fill", accessibilityDescription: "HTTP")
      eventTextField.isHidden = true
      var string = AttributedString(log.method.rawValue + " ")
      string[AttributeScopes.AppKitAttributes.FontAttribute.self] = .monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
      var url = AttributedString(log.url.absoluteString)
      url[AttributeScopes.AppKitAttributes.FontAttribute.self] = .monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
      string.append(url)
      let style = NSMutableParagraphStyle()
      style.lineBreakMode = .byTruncatingTail
      string[AttributeScopes.AppKitAttributes.ParagraphStyleAttribute.self] = style
      primaryTextField.attributedStringValue = NSAttributedString(string)
    }
  }

  override func prepareForReuse() {
    primaryTextField.isHidden = false
    eventTextField.isHidden = false
    eventTextField.textColor = .labelColor
  }
}
