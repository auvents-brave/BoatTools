// The saved-connection kinds for the C ABI: a URL (Signal K over the web, or
// NMEA over tcp/udp), a Victron VRM installation, a recorded log replayed from
// disk, and a parametrable synthetic passage — the same set the Swift app's
// Mode preferences offer, built the same way so both hosts behave alike.

internal import BoatToolsKit
internal import Foundation

// MARK: - URL

/// The ports a URL may name. Port 0 parses happily but binds to whatever the
/// kernel hands out, which is never what a saved connection means.
private let validPorts = 1...65_535

/// Opens a connection described by a URL, exactly as the Swift app's Mode
/// panel does:
///
/// - `http`, `https`, `ws`, `wss` — the authenticated Signal K WebSocket
///   client. Pass `username` / `password` only when the server requires a
///   login; NULL or empty means anonymous.
/// - `tcp` — an NMEA client stream (host and port required). Transmit-capable,
///   so the device inventory and the pilot / windlass commands work over it.
/// - `udp` — an NMEA receiver bound to the URL's port; a host, when given,
///   is joined as a multicast group.
///
/// Signal K sources carry no NMEA 2000 session, so they answer no device
/// inventory and accept no commands — that is the protocol's doing, not a
/// limitation of this call.
///
/// - Returns: A handle (> 0) for `boattools_bridge_poll` /
///   `boattools_bridge_close`, or 0 when the URL is missing, unparseable, of
///   an unsupported scheme, or short of the host / port that scheme needs.
@_cdecl("boattools_bridge_open_url")
public func boattools_bridge_open_url(
	_ url: UnsafePointer<CChar>?,
	_ username: UnsafePointer<CChar>?,
	_ password: UnsafePointer<CChar>?
) -> Int64 {
	guard let url else { return 0 }
	let string = String(cString: url)
	guard let components = URLComponents(string: string),
		let scheme = components.scheme?.lowercased()
	else { return 0 }
	let user = username.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
	let secret = password.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }

	switch scheme {
	case "http", "https", "ws", "wss":
		let config = SignalKClient.Config(
			baseURL: string, token: nil, username: user, password: secret)
		// `liveStream` resolves the endpoint (and logs in) before yielding, so
		// it must be awaited before the registry can consume it.
		let stream = awaitBlocking { await SignalKClient.liveStream(config: config) }
		return registry.open(stream)

	case "tcp":
		guard let host = components.host, host.isEmpty == false,
			let port = components.port, validPorts.contains(port)
		else { return 0 }
		let session = NMEATransport.session(config: NMEATransportConfig(mode: .tcp(host: host, port: port)))
		return registry.open(session.frames, session: session)

	case "udp":
		guard let port = components.port, validPorts.contains(port) else { return 0 }
		let multicast = components.host.flatMap { $0.isEmpty ? nil : $0 }
		let config = NMEATransportConfig(mode: .udp(listenPort: port, multicastGroup: multicast))
		let session = NMEATransport.session(config: config)
		return registry.open(session.frames, session: session)

	default:
		return 0
	}
}

// MARK: - Victron VRM

/// Opens a Victron VRM installation, polling its diagnostics into the same
/// canonical metrics every other source produces.
///
/// The access token is a secret: hold it in the host's credential store, not
/// in a preferences file.
/// - Parameters:
///   - token: The VRM API access token.
///   - siteID: The installation's site id.
///   - pollSeconds: How often to poll; clamped to at least 10 s, VRM being a
///     cloud API with rate limits rather than a live feed.
/// - Returns: A handle (> 0), or 0 when the token is empty or the site id is 0.
@_cdecl("boattools_bridge_open_vrm")
public func boattools_bridge_open_vrm(
	_ token: UnsafePointer<CChar>?, _ siteID: Int32, _ pollSeconds: Int32
) -> Int64 {
	guard let token, siteID != 0 else { return 0 }
	let accessToken = String(cString: token)
	guard accessToken.isEmpty == false else { return 0 }
	let stream = VictronVRMClient.frameStream(
		accessToken: accessToken,
		siteId: Int(siteID),
		pollInterval: .seconds(max(10, Int(pollSeconds)))
	)
	return registry.open(stream)
}

// MARK: - Replay

/// Replays a recorded NMEA log from disk as though it were live.
/// - Parameters:
///   - path: The log file's path. The host resolves it — this call gets a
///     plain path, so a sandboxed host must open its security scope first and
///     keep it open for the connection's life.
///   - useTimestamps: Play at the file's own pace, from its embedded
///     timestamps. When false, `framesPerSecond` sets a fixed rate.
///   - framesPerSecond: Source lines per second when not using timestamps;
///     values ≤ 0 fall back to 10.
///   - loop: Restart from the top once the file is exhausted.
/// - Returns: A handle (> 0), or 0 when the path is missing or empty.
@_cdecl("boattools_bridge_open_replay")
public func boattools_bridge_open_replay(
	_ path: UnsafePointer<CChar>?, _ useTimestamps: Int32, _ framesPerSecond: Double, _ loop: Int32
) -> Int64 {
	guard let path else { return 0 }
	let file = String(cString: path)
	guard file.isEmpty == false else { return 0 }
	let pacing: ReplayPacing =
		useTimestamps != 0
		? .respectTimestamps
		: .framesPerSecond(framesPerSecond > 0 ? framesPerSecond : 10)
	return registry.open(NMEATransport.replayStream(path: file, pacing: pacing, loop: loop != 0))
}

// MARK: - Simulation

/// Opens a synthetic passage — the parametrable form of
/// `boattools_bridge_open_simulator`, which always sails the default route.
///
/// Like the simulator, this is a full session: the passage plus a simulated
/// NMEA 2000 network (an autopilot and two windlasses) that answers the roll
/// call and obeys the command functions.
/// - Parameters:
///   - routeID: A preset route's identifier (e.g. `monaco-maddalena`). NULL or
///     empty sails the default route.
///   - speedKnots: Speed through the water; ≤ 0 defaults to 6 kn.
///   - speedUp: Fast-forwards the movement (1 = real time); clamped to ≥ 1.
///   - loop: Sail the route again on arrival.
/// - Returns: A handle (> 0), or 0 when `routeID` names no preset.
@_cdecl("boattools_bridge_open_simulation")
public func boattools_bridge_open_simulation(
	_ routeID: UnsafePointer<CChar>?, _ speedKnots: Double, _ speedUp: Double, _ loop: Int32
) -> Int64 {
	let identifier = routeID.map { String(cString: $0) } ?? ""
	let route: SimulatorRoute? =
		identifier.isEmpty ? .monacoToMaddalena : SimulatorRoute.preset(id: identifier)
	guard let route else { return 0 }
	let session = NMEASimulator.session(
		route: route,
		speedKnots: speedKnots > 0 ? speedKnots : 6,
		timeMultiplier: max(1, speedUp),
		loop: loop != 0
	)
	return registry.open(session.frames, session: session)
}

// MARK: - Connection test

/// Waits for an open connection to deliver its first data — the check behind
/// the Mode panel's status pills.
///
/// Open the connection with whichever `boattools_bridge_open_*` call fits,
/// test it, then close it. Blocks for up to `timeoutSeconds` — call from a
/// background thread.
/// - Returns: 1 when data arrived; 0 on timeout, on a stream that ended or
///   failed without delivering anything, or for an unknown handle.
@_cdecl("boattools_bridge_await_data")
public func boattools_bridge_await_data(_ handle: Int64, _ timeoutSeconds: Double) -> Int32 {
	guard let connection = registry.connection(handle) else { return 0 }
	let deadline = Date().addingTimeInterval(timeoutSeconds > 0 ? timeoutSeconds : 8)
	while Date() < deadline {
		let probe = connection.probe()
		if probe.received { return 1 }
		// A stream that has already stopped will never deliver anything: fail
		// now rather than sit out the whole timeout.
		if probe.status != "running" { return 0 }
		Thread.sleep(forTimeInterval: 0.1)
	}
	return connection.probe().received ? 1 : 0
}
