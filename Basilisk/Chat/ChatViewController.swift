import Cocoa
import Combine
import Serpent
import SwiftyJSON
import os.log
import OrderedCollections

final class ChatViewController: NSSplitViewController {
  var navigatorViewController: NavigatorViewController {
    splitViewItems[0].viewController as! NavigatorViewController
  }

  var statusBarController: StatusBarContainerController {
    (splitViewItems[1].viewController as! StatusBarContainerController)
  }

  var messagesViewController: MessagesViewController {
    statusBarController.containedViewController as! MessagesViewController
  }

  var session: Session?

  var client: Client? {
    session?.client
  }

  var account: Account? {
    session?.account
  }

  var gatewayPacketHandler: Task<Void, Never>?

  private var cancellables = Set<AnyCancellable>()

  /// The currently selected guild ID.
  var selectedGuildID: Ref<Guild>?

  /// The currently selected channel.
  ///
  /// This can be a private channel or a guild channel, so this isn't a `Ref`.
  var focusedChannelID: Snowflake? {
    didSet {
      exhaustedMessageHistory = false
    }
  }

  /// A Boolean indicating whether we have reached the top of the message
  /// history for the focused channel.
  var exhaustedMessageHistory = false

  /// A Boolean indicating whether we are currently requesting more message
  /// history.
  var requestingMoreHistory = false

  /// The currently selected guild.
  var selectedGuild: Guild? {
    get async {
      guard let client, let selectedGuildID else { return nil }
      return await client.cache[selectedGuildID]
    }
  }

  /// The current user this view controller knows about.
  ///
  /// This information is copied from the cache because we need quick access to
  /// it without having to `await`.
  private var knownCurrentUser: CurrentUser?

  /// The private channels this view controller knows about.
  ///
  /// This information is copied from the cache because we need quick access to
  /// it without having to `await`.
  private var knownPrivateChannels: OrderedDictionary<PrivateChannel.ID, PrivateChannel>?

  /// The guilds this view controller knows about.
  ///
  /// This information is copied from the cache because we need quick access to
  /// it without having to `await`.
  private var knownGuilds: [Guild.ID: Guild]?

  /// A subset of the cache's users that we need to know about in order to
  /// properly display private channels.
  ///
  /// This information is copied from the cache because we need quick access to
  /// it without having to `await`.
  private var knownPrivateParticipants: [User.ID: User]?

  let log = Logger(subsystem: "zone.slice.Basilisk", category: "chat-view-controller")

  deinit {
    NSLog("ChatViewController deinit")

    // TODO(skip): The fact that disconnection happens asynchronously isn't
    // ideal, because it means that we can't guarantee a disconnect before
    // deinitializing. Is there a way to get around this?
    Task {
      try! await tearDownClient()
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    splitViewItems[1].titlebarSeparatorStyle = .shadow

    navigatorViewController.delegate = self
    messagesViewController.delegate = self
  }

  func requestedToLoadMoreHistory() {
    guard !exhaustedMessageHistory else {
      log.info("message history is exhausted, not loading more posts")
      return
    }

    guard let client = client, !requestingMoreHistory,
          let focusedChannelID = focusedChannelID
    else {
      return
    }

    log.debug("requesting more messages")
    requestingMoreHistory = true
    let limit = 50

    let request = try! client.http.apiRequest(
      to: "/channels/\(focusedChannelID.string)/messages",
      query: [
        "limit": String(limit),
        "before": String(messagesViewController.oldestMessageID!.uint64),
      ]
    )!

    Task { [request] in
      let messages: [Message] = try! await client.http.requestDecoding(
        request,
        withSpoofedHeadersFor: .xhr
      )

      if messages.isEmpty {
        log.debug("received 0 older messages, so history is exhausted")
        exhaustedMessageHistory = true
        requestingMoreHistory = false
        return
      }

      self.messagesViewController.prependOldMessages(messages)

      if messages.count < limit {
        log.debug("received \(messages.count) messages; less than limit of \(limit), so history is exhausted")
        exhaustedMessageHistory = true
      }

      requestingMoreHistory = false
    }
  }

  func selectChannel(withID channelRef: Snowflake) async {
    guard let client = client else {
      return
    }

    focusedChannelID = channelRef

    if let selectedGuild = await selectedGuild,
       let channel = selectedGuild.channels.first(where: { $0.id == channelRef }) {
      view.window?.title = selectedGuild.name
      view.window?.subtitle = "#\(channel.name)" + (channel.topic.map { " \u{2014} \($0)" } ?? "")
    } else if let privateChannel: PrivateChannel = await client.cache[channelRef.ref()] {
      view.window?.title = privateChannel.name()
      view.window?.subtitle = ""
    }

    let request = try! client.http.apiRequest(to: "/channels/\(channelRef.string)/messages", query: ["limit": "50"])!

    Task { [request] in
      do {
        let messages: [Message] = try await client.http.requestDecoding(request, withSpoofedHeadersFor: .xhr)
        self.messagesViewController.applyInitialMessages(messages)

        if messages.count < 50 {
          log.debug("entire message history is <50, exhausted")
          exhaustedMessageHistory = true
        }
      } catch {
        log.error("failed to fetch messages: \(String(describing: error), privacy: .public)")
        self.messagesViewController.applyInitialMessages([])
      }
    }
  }

  func handleCommand(
    named command: String,
    arguments: [String]
  ) async throws {
    let say = { message in
      self.messagesViewController.appendToConsole(line: message)
    }

    switch command {

    case "disconnect":
      try await tearDownClient()
      say("[system] disconnected!")
    default:
      say("[system] dunno what \"\(command)\" is!")
    }
  }

  /// Sort a dictionary of `Guild`s according to the user's current settings.
  func sortGuildsAccordingToUserSettings(_ guilds: [Guild.ID: Guild]) async -> [Guild]? {
    guard let userSettings: JSON = await client?.cache.userSettings.value,
          let guildPositions = userSettings["guild_positions"].array?.compactMap(\.string).map(Snowflake.init(string:))
    else { return Array(guilds.values) }

    return Array(guilds.values).sorted { a, b in
      let aIndex = guildPositions.firstIndex(of: a.id) ?? 0
      let bIndex = guildPositions.firstIndex(of: b.id) ?? 0
      return aIndex < bIndex
    }
  }

  /// Associates this view controller with an existing session.
  ///
  /// This method doesn't instruct the session's client to connect.
  func associateWithSession(_ session: Session, immediatelyLoading immediatelyLoad: Bool = true) {
    self.session = session
    let client = session.client

    // Cancel all existing sinks.
    cancellables = []

    setUpGatewayPacketHandler()
    setupConnectionStateSink()

    client.gatewayConnection.reconnects.receive(on: DispatchQueue.main)
      .sink { [unowned self] _ in
        // The websocket connection has been reset, so we need to reset our sink
        // too.
        Task { await self.setupConnectionStateSink() }
      }
      .store(in: &cancellables)

    client.guildsChanged.receive(on: DispatchQueue.main)
      .sink { [unowned self] _ in
        Task { await self.fetchGuilds() }
      }
      .store(in: &cancellables)

    client.privateChannelsChanged.receive(on: DispatchQueue.main)
      .sink { [unowned self] _ in
        Task { await self.fetchPrivateChannels() }
      }
      .store(in: &cancellables)

    client.gatewayConnection.sentPackets.receive(on: DispatchQueue.main)
      .sink { (json, string) in
        let data = string.data(using: .utf8)!

        let packet = try! JSONDecoder().decode(GatewayPacket<JSON>.self, from: data)
        let anyPacket = AnyGatewayPacket(packet: packet, raw: data)

        let logMessage = LogMessage(
          direction: .sent,
          timestamp: Date.now,
          variant: .gateway(anyPacket)
        )

        (NSApp.delegate as! AppDelegate).gatewayLogStore.appendMessage(logMessage)
      }
      .store(in: &cancellables)

    Task {
      await client.cache.userSettings
        .receive(on: RunLoop.main)
        .sink { [unowned self] json in
          guard let json = json, json["guild_positions"].exists() || json["guild_folders"].exists() else { return }
          // Resort guilds.
          Task { await self.fetchGuilds() }
        }
        .store(in: &cancellables)
    }

    // If instructed to (for example, if we're a new tab/window spawned off of
    // an existing session), then immediately try to fetch the necessary state
    // for reloading the navigator.
    //
    // We need to do this because the relevant subscribers set up above aren't
    // interacting with `CurrentValueSubject`s, which immediately send a value
    // upon attaching a subscriber. So, we need to initiate the fetches
    // manually.
    if immediatelyLoad {
      Task {
        await self.fetchPrivateChannels()
        await self.fetchGuilds()
      }
    }
  }

  /// Fetch the necessary state from the client cache to display private
  /// channels and reload the navigator.
  private func fetchPrivateChannels() async {
    guard let client else { return }

    let privateChannels = await client.cache.privateChannels
    knownPrivateChannels = privateChannels

    // Resolve all private channel participants using information in the
    // cache.
    let allParticipants: Set<Ref<User>> = privateChannels.values.map({ privateChannel -> Set<Ref<User>> in
      switch privateChannel {
      case .groupDM(let gdm): return gdm.recipients
      case .dm(let dm): return Set(dm.recipientIDs)
      }
    }).reduce(Set(), { n, r in n.union(r) })
    let resolvedUsers = await client.cache.batchResolve(users: allParticipants)
    knownPrivateParticipants = Dictionary(uniqueKeysWithValues: resolvedUsers.map { ($0.id, $0) })
    if resolvedUsers.count != allParticipants.count {
      log.warning("failed to resolve all private participants")
    }

    navigatorViewController.reload(privateChannelIDs: privateChannels.values.map(\.id))
  }

  /// Fetch all guilds from the cache, sorting them and reloading the
  /// navigator.
  private func fetchGuilds() async {
    guard let client = client else { return }
    let guilds = await client.cache.guilds
    guard let sortedGuilds = await sortGuildsAccordingToUserSettings(guilds) else { return }
    knownGuilds = guilds
    navigatorViewController.reload(guildIDs: sortedGuilds.map(\.id))
  }

  private func setupConnectionStateSink() {
    client!.gatewayConnection.connectionState!.receive(on: RunLoop.main)
      .sink { [weak self] state in
        let connectionStatus: ConnectionStatus
        let connectionLabel: String

        switch state {
        case .connecting:
          connectionStatus = .connecting
          connectionLabel = "Connecting to Discord???"
        case .failed:
          connectionStatus = .disconnected
          connectionLabel = "Connection failed!"
        case .disconnected:
          connectionStatus = .disconnected
          connectionLabel = "Disconnected!"
        case .connected:
          connectionStatus = .connected
          connectionLabel = "Connected."
        case .unviable:
          connectionStatus = .connecting
          connectionLabel = "Network connection has become unviable???"
        }

        self?.statusBarController.connectionStatus.connectionStatus = connectionStatus
        self?.statusBarController.connectionStatusLabel.stringValue = connectionLabel
      }
      .store(in: &cancellables)
  }

  func logPacket(_ packet: AnyGatewayPacket) {
    let logMessage = LogMessage(
      direction: .received,
      timestamp: Date.now,
      variant: .gateway(packet)
    )

    let delegate = NSApp.delegate as! AppDelegate
    delegate.gatewayLogStore.appendMessage(logMessage)
  }

  func setUpGatewayPacketHandler() {
    guard let client = client else { return }

    gatewayPacketHandler = Task.detached(priority: .high) {
      for await packet in client.gatewayConnection.receivedPackets.bufferInfinitely()
        .values
      {
        await self.logPacket(packet)
        await self.handleGatewayPacket(packet)
      }
    }
  }

  func handleGatewayPacket(_ packet: AnyGatewayPacket) async {
    if let eventName = packet.packet.eventName, eventName == "MESSAGE_CREATE" {
      let data = packet.packet.eventData!

      let channelID = Snowflake(string: data["channel_id"].string!)
      guard channelID == focusedChannelID else { return }

      let message: Message = try! packet.reparse()
      messagesViewController.appendNewlyReceivedMessage(message)
    }
  }

  /// Disconnect from the gateway and tear down the Discord client.
  func tearDownClient() async throws {
    log.notice("tearing down client")
    gatewayPacketHandler?.cancel()

    // Disconnect from the Discord gateway with a 1000 close code.
    do {
      try await client?.disconnect()
    } catch {
      log.error("failed to disconnect, dealloc-ing anyways: \(error)")
    }
    log.info("disconnected")

    // Release the session here. It won't necessarily dealloc here, since it'll
    // be held by the app delegate. Some Combine subscribers will not get a
    // chance to respond to the disconnect, but that's fine since we've already
    // cleanly disconnected by now.
    session = nil

    focusedChannelID = nil
    selectedGuildID = nil

    navigatorViewController.reload(guildIDs: [])
    knownGuilds = [:]

    navigatorViewController.reload(privateChannelIDs: [])
    knownPrivateChannels = [:]
    knownPrivateParticipants = [:]

    knownCurrentUser = nil

    messagesViewController.applyInitialMessages([])
    view.window?.title = "Basilisk"
    view.window?.subtitle = ""
  }
}

extension ChatViewController: MessagesViewControllerDelegate {
  func messagesController(_ messagesController: MessagesViewController, commandInvoked command: String, arguments: [String]) {
    Task {
      do {
        try await handleCommand(named: command, arguments: arguments)
      } catch {
        log.error("failed to handle command: \(error, privacy: .public)")
        self.messagesViewController
          .appendToConsole(
            line: "[system] failed to handle command: \(error)"
          )
      }
    }
  }

  func messagesController(_ messagesController: MessagesViewController, messageSent message: String) {
    guard let focusedChannelID = self.focusedChannelID, let client = self.client else {
      return
    }

    Task {
      do {
        let request = try client.http.apiRequest(
          to: "/channels/\(focusedChannelID.string)/messages",
          method: .post,
          body: [
            "content": message,
            "tts": false,
            "nonce": String(Int.random(in: 0...1_000_000_000))
          ]
        )!
        let _ = try await client.http.request(request, withSpoofedHeadersFor: .xhr)
      } catch {
        log.error("failed to send message: \(error, privacy: .public)")
        messagesViewController.appendToConsole(line: "[system] failed to send message: \(error)")
      }
    }
  }

  func messagesControllerDidScrollNearTop(_ messagesController: MessagesViewController) {
    requestedToLoadMoreHistory()
  }
}

extension ChatViewController: NavigatorViewControllerDelegate {
  func navigatorViewController(_ navigatorViewController: NavigatorViewController,
                               didSelectChannelWithID channelID: GuildChannel.ID,
                               inGuildWithID guildID: Guild.ID?) {
    selectedGuildID = guildID?.ref()
    Task {
      await selectChannel(withID: channelID)
    }
  }

  func navigatorViewController(_ navigatorViewController: NavigatorViewController,
                               requestingPrivateChannelWithID id: PrivateChannel.ID) -> PrivateChannel {
    guard let privateChannel = knownPrivateChannels?[id] else {
      fatalError("navigator request non-existent private channel with id: \(id), or client wasn't ready yet")
    }
    return privateChannel
  }

  func navigatorViewController(_ navigatorViewController: NavigatorViewController,
                               requestingGuildWithID id: Guild.ID
  ) -> Guild {
    guard let guild = knownGuilds?[id] else {
      fatalError("navigator requested non-existent guild with id: \(id), or client wasn't ready yet")
    }

    return guild
  }

  func navigatorViewController(_ navigatorViewController: NavigatorViewController,
                               didRequestCurrentUserID _: Void
  ) -> Snowflake? {
    knownCurrentUser?.id
  }

  func navigatorViewController(_ navigatorViewController: NavigatorViewController,
                               didRequestPrivateParticipantsForChannel privateChannelID: PrivateChannel.ID) -> [User] {
    guard let privateChannel = knownPrivateChannels?[privateChannelID] else { return [] }

    switch privateChannel {
    case .dm(let dm): return knownPrivateParticipants?[dm.recipient!.id].map { [$0] } ?? []
    case .groupDM(let gdm): return gdm.recipients.compactMap { knownPrivateParticipants?[$0.id] }
    }
  }
}
