import Cocoa
import FineJSON
import RichJSONParser

extension ChatViewController {
  func appendToConsole(line: String) {
    consoleTextView.string += line + "\n"

    let clipView = consoleScrollView.contentView
    let documentView = consoleScrollView.documentView!
    let isScrolledToBottom = clipView.bounds.origin.y + clipView.bounds
      .height == documentView.frame.height

    if isScrolledToBottom {
      consoleTextView.scrollToEndOfDocument(self)
    }
  }

  func handleCommand(
    named command: String,
    arguments: [String]
  ) async throws {
    switch command {
    case "connect":
      guard let token = arguments.first else {
        appendToConsole(line: "[system] you need a user token, silly!")
        return
      }

      if client != nil {
        try await tearDownClient()
      }

      do {
        try await connect(authorizingWithToken: token)
      } catch {
        appendToConsole(line: "[system] failed to connect: \(error)")
      }
    case "focus":
      guard let channelIDString = arguments.first,
            let channelID = UInt64(channelIDString)
      else {
        appendToConsole(line: "[system] provide a channel id... maybe...")
        return
      }

      focusedChannelID = channelID
      appendToConsole(line: "[system] focusing into <#\(channelID)>")
    case "disconnect":
      try await tearDownClient()
      appendToConsole(line: "[system] disconnected!")
    default:
      appendToConsole(line: "[system] dunno what \"\(command)\" is!")
    }
  }

  @IBAction func inputTextFieldAction(_ sender: NSTextField) {
    let fieldText = sender.stringValue
    sender.stringValue = ""

    guard !fieldText.isEmpty else { return }

    if fieldText.starts(with: "/") {
      let tokens = fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: " ")
      let firstToken = tokens.first!
      let firstTokenWithoutSlash =
        firstToken[firstToken.index(after: firstToken.startIndex) ..< firstToken
          .endIndex]

      Task {
        do {
          try await handleCommand(
            named: String(firstTokenWithoutSlash),
            arguments: tokens.dropFirst().map { String($0) }
          )
        } catch {
          appendToConsole(line: "[system] failed to handle command: \(error)")
        }
      }

      return
    }

    if let focusedChannelID = focusedChannelID, let client = client {
      let url = client.http.baseURL.appendingPathComponent("api")
        .appendingPathComponent("v9")
        .appendingPathComponent("channels")
        .appendingPathComponent(String(focusedChannelID))
        .appendingPathComponent("messages")
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      let randomNumber = Int.random(in: 0 ... 1_000_000_000)
      let json: JSON = .object(.init([
        "content": .string(fieldText),
        "tts": .boolean(false),
        "nonce": .string(String(randomNumber)),
      ]))
      let encoder = FineJSONEncoder()
      encoder.jsonSerializeOptions = JSONSerializeOptions(isPrettyPrint: false)
      encoder.optionalEncodingStrategy = .explicitNull
      request.addValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try! encoder.encode(json)
      Task { [request] in
        try! await client.http.request(
          request,
          withSpoofedHeadersOfRequestType: .xhr
        )
      }
    }
  }
}