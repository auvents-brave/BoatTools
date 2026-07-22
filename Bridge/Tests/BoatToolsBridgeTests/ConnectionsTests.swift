import Foundation
import Testing

@testable import BoatToolsBridge

/// The C ABI's connection surface. These pin the *rejections* above all: a
/// host that mistypes a URL must get 0 back, not a handle that silently never
/// delivers anything.
@Suite("Bridge connections")
struct ConnectionsTests {

	// MARK: open_url

	@Test("A URL with no scheme, or an unsupported one, is refused")
	func urlSchemeIsChecked() {
		#expect("192.168.1.10:2000".withCString { boattools_bridge_open_url($0, nil, nil) } == 0)
		#expect("ftp://192.168.1.10:21".withCString { boattools_bridge_open_url($0, nil, nil) } == 0)
		#expect("".withCString { boattools_bridge_open_url($0, nil, nil) } == 0)
		#expect(boattools_bridge_open_url(nil, nil, nil) == 0)
	}

	@Test("tcp:// needs both a host and a port")
	func tcpNeedsHostAndPort() {
		#expect("tcp://192.168.1.10".withCString { boattools_bridge_open_url($0, nil, nil) } == 0)
		#expect("tcp://:2000".withCString { boattools_bridge_open_url($0, nil, nil) } == 0)
	}

	@Test("udp:// needs a port, but no host — the host is the multicast group")
	func udpNeedsAPort() {
		#expect("udp://".withCString { boattools_bridge_open_url($0, nil, nil) } == 0)

		let handle = "udp://0.0.0.0:0".withCString { boattools_bridge_open_url($0, nil, nil) }
		#expect(handle == 0, "port 0 is not a port")

		// A bare port opens a plain receiver. Nothing is sent to it here — the
		// point is that the handle is issued.
		let listener = "udp://:57321".withCString { boattools_bridge_open_url($0, nil, nil) }
		#expect(listener > 0)
		boattools_bridge_close(listener)
	}

	@Test("A tcp:// URL yields a handle even before the server answers")
	func tcpOpensOptimistically() {
		// Nothing listens on this port: the connection is still handed over, and
		// it is the poll status that later reports the failure. A host must not
		// have to wait on `open` to know whether the address parsed.
		let handle = "tcp://127.0.0.1:59999".withCString { boattools_bridge_open_url($0, nil, nil) }
		#expect(handle > 0)
		boattools_bridge_close(handle)
	}

	// MARK: open_vrm

	@Test("VRM refuses an empty token or an absent site")
	func vrmNeedsTokenAndSite() {
		#expect("".withCString { boattools_bridge_open_vrm($0, 12345, 60) } == 0)
		#expect("token".withCString { boattools_bridge_open_vrm($0, 0, 60) } == 0)
		#expect(boattools_bridge_open_vrm(nil, 12345, 60) == 0)
	}

	// MARK: open_replay

	@Test("Replay refuses an empty path")
	func replayNeedsAPath() {
		#expect("".withCString { boattools_bridge_open_replay($0, 1, 10, 0) } == 0)
		#expect(boattools_bridge_open_replay(nil, 1, 10, 0) == 0)
	}

	@Test("Replay reads a recorded log back as metrics")
	func replayPlaysAFile() throws {
		let path = FileManager.default.temporaryDirectory
			.appendingPathComponent("bridge-replay-\(UUID().uuidString).log").path
		// Real sentences, checksums included — the parser rejects anything else,
		// so a made-up `*XX` would replay as silence.
		let log = """
			$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A
			$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47

			"""
		try log.write(toFile: path, atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(atPath: path) }

		// A fast fixed rate rather than the file's own timing: the test should
		// not wait on timestamps a minute apart.
		let handle = path.withCString { boattools_bridge_open_replay($0, 0, 50, 0) }
		#expect(handle > 0)
		defer { boattools_bridge_close(handle) }
		#expect(boattools_bridge_await_data(handle, 5) == 1)
	}

	// MARK: open_simulation

	@Test("An unknown route id is refused, a known one sails")
	func simulationChecksItsRoute() {
		#expect("no-such-route".withCString { boattools_bridge_open_simulation($0, 6, 1, 0) } == 0)

		let handle = "monaco-maddalena".withCString { boattools_bridge_open_simulation($0, 6, 60, 1) }
		#expect(handle > 0)
		boattools_bridge_close(handle)
	}

	@Test("An empty route id sails the default passage")
	func simulationDefaultsItsRoute() {
		let handle = "".withCString { boattools_bridge_open_simulation($0, 6, 60, 1) }
		#expect(handle > 0)
		boattools_bridge_close(handle)
	}

	// MARK: await_data

	@Test("An unknown handle never reports data")
	func awaitRejectsUnknownHandles() {
		#expect(boattools_bridge_await_data(999_999, 0.5) == 0)
	}

	@Test("A live source reports data, and the wait ends as soon as it arrives")
	func awaitSeesTheSimulator() {
		let handle = boattools_bridge_open_simulator(6, 60)
		#expect(handle > 0)
		defer { boattools_bridge_close(handle) }

		let started = Date()
		#expect(boattools_bridge_await_data(handle, 10) == 1)
		// The simulator emits within a second; if this took the whole timeout,
		// the poll loop is not noticing the arrival.
		#expect(Date().timeIntervalSince(started) < 9)
	}

	@Test("A source that fails outright does not hold the wait open")
	func awaitGivesUpOnADeadStream() {
		// Nothing listens here, so the stream fails long before a generous
		// timeout elapses — the wait must follow the stream, not the clock.
		let handle = "tcp://127.0.0.1:59998".withCString { boattools_bridge_open_url($0, nil, nil) }
		#expect(handle > 0)
		defer { boattools_bridge_close(handle) }

		let started = Date()
		#expect(boattools_bridge_await_data(handle, 30) == 0)
		#expect(Date().timeIntervalSince(started) < 25)
	}
}
