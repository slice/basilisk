import Combine
import Dispatch
import FineJSON
import Foundation
import GenericJSON
import Network
import os
import RichJSONParser

// MARK: Client

/// A Discord user client.
public class Client {
  /// The user authentication token used to connect to Discord.
  var token: String

  /// The Discord API endpoint that we communicate with.
  var endpoint: URL

  /// The disguise to use when communicating with Discord.
  var disguise: Disguise

  private var log: Logger

  /// The connection to the Discord gateway.
  public var gatewayConnection: GatewayConnection!

  /// The Discord API HTTP client.
  public var http: HTTP!

  var gatewaySink: AnyCancellable!

  /// The user's settings, received from the `READY` packet.
  public private(set) var userSettings: [String: GenericJSON.JSON]?

  /// The guilds that this client has.
  public private(set) var guilds: [Guild] = []
  public private(set) var guildsChanged = PassthroughSubject<Void, Never>()

  static let defaultDisguise = Disguise(
    userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) discord/0.0.278 Chrome/91.0.4472.164 Electron/13.4.0 Safari/537.36",
    capabilities: 125,
    os: "Mac OS X",
    browser: "Discord Client",
    releaseChannel: .canary,
    clientVersion: "0.0.278",
    osVersion: "21.2.0",
    osArch: "x64",
    systemLocale: "en-US",
    clientBuildNumber: 105_780,
    clientEventSource: nil
  )

  public init(branch: Branch, token: String) {
    guard !token.isEmpty else {
      preconditionFailure("attempted to make client with empty token")
    }
    self.token = token

    guard let endpoint = branch.baseURL else {
      preconditionFailure(
        "attempted to make client with branch \(branch), which has no base url"
      )
    }
    self.endpoint = endpoint

    // TODO(skip): Don't hardcode these. Scrape the necessary values at runtime.
    disguise = Self.defaultDisguise

    log = Logger(subsystem: "zone.slice.Contempt", category: "client")
    gatewayConnection = GatewayConnection(
      token: self.token,
      disguise: disguise
    )

    http = HTTP(baseURL: endpoint, token: token, disguise: disguise)
  }

  /// Connect to the Discord gateway.
  public func connect() {
    gatewaySink = gatewayConnection.packets.sink { [weak self] packet in
      self?.processPacket(packet)
    }

    gatewayConnection.connect(
      toGateway: URL(string: "wss://gateway.discord.gg/?encoding=json&v=9")!,
      fromDiscordEndpoint: endpoint
    )
  }

  func processPacket(_ packet: GatewayPacket) {
    guard let eventName = packet.eventName else {
      return
    }

    switch eventName {
    case "READY":
      self.processReadyPacket(packet)
    case "GUILD_CREATE":
      self.guilds.append(Guild(json: packet.eventData!))
      self.guildsChanged.send()
    default:
      break
    }
  }

  func processReadyPacket(_ packet: GatewayPacket) {
    log.debug("getting READY...")

    let object = packet.eventData!.objectValue!

    userSettings = object["user_settings"]!.objectValue!

    guilds = object["guilds"]!.arrayValue!.map(Guild.init(json:))
    guildsChanged.send()
  }

  /// Disconnect from the Discord gateway.
  public func disconnect() async throws {
    try await gatewayConnection.disconnect()
  }
}
