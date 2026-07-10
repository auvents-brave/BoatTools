import Foundation
import Testing

@testable import BoatToolsKit

/// Unit tests for ``SimulatedDevices`` — the simulator's NMEA 2000 network:
/// one autopilot, two windlasses, command-obeying and status-broadcasting.
@Suite("Simulated devices")
struct SimulatedDevicesTests {

	@Test func `the network announces a pilot and two windlasses`() {
		let devices = SimulatedDevices()
		let frames = devices.statusFrames(heading: 100, dt: 1)
		let claims = frames.filter { $0.pgn == 60928 }
		#expect(claims.map(\.source) == [204, 18, 19])

		var directory = NMEA2000DeviceDirectory()
		for frame in frames {
			directory.apply(pgn: frame.pgn, source: frame.source, data: frame.data)
		}
		let pilot = NMEA2000Commands.autopilot(in: directory.devices)
		#expect(pilot?.brand == .raymarineEvolution)
		#expect(pilot?.device.address == 204)
		#expect(pilot?.device.modelID == "EV-1 Course Computer")
		#expect(NMEA2000Commands.windlass(in: directory.devices)?.address == 18)
		#expect(directory[19]?.manufacturerName == "Vetus Maxwell")

		// Claims are announced once, then again after the next roll call.
		#expect(devices.statusFrames(heading: 100, dt: 1).filter { $0.pgn == 60928 }.isEmpty)
		devices.handle(.nmea2000(pgn: 59904, destination: 255, priority: 6, data: [0, 0xEE, 0]))
		#expect(devices.statusFrames(heading: 100, dt: 1).filter { $0.pgn == 60928 }.count == 3)
	}

	@Test func `the pilot obeys mode writes and keystrokes`() throws {
		let devices = SimulatedDevices()
		_ = devices.statusFrames(heading: 87, dt: 1)  // learn the heading

		// Engage via the real Raymarine recipe: mode 64, target = heading.
		for message in try NMEA2000Commands.messages(
			for: .engage, brand: .raymarineEvolution, destination: 204)
		{
			devices.handle(message)
		}
		var frames = devices.statusFrames(heading: 87, dt: 1)
		let mode = try #require(frames.first { $0.pgn == 65379 })
		#expect(UInt16(mode.data[2]) | UInt16(mode.data[3]) << 8 == 64)
		var target = try #require(frames.first { $0.pgn == 65360 })
		#expect(abs(headingDegrees(target.data) - 87) < 0.1)

		// +10° and −1° keystrokes move the locked heading to 96.
		for message in try NMEA2000Commands.messages(
			for: .adjustHeading(degrees: 10), brand: .raymarineEvolution, destination: 204)
			+ NMEA2000Commands.messages(
				for: .adjustHeading(degrees: -1), brand: .raymarineEvolution, destination: 204)
		{
			devices.handle(message)
		}
		frames = devices.statusFrames(heading: 87, dt: 1)
		target = try #require(frames.first { $0.pgn == 65360 })
		#expect(abs(headingDegrees(target.data) - 96) < 0.1)

		// Standby stops the locked-heading broadcast.
		for message in try NMEA2000Commands.messages(
			for: .standby, brand: .raymarineEvolution, destination: 204)
		{
			devices.handle(message)
		}
		frames = devices.statusFrames(heading: 87, dt: 1)
		#expect(frames.contains { $0.pgn == 65360 } == false)
	}

	@Test func `a windlass order runs the chain until stopped`() throws {
		let devices = SimulatedDevices()
		_ = devices.statusFrames(heading: 0, dt: 1)

		// Windlass 1 (instance 1) pays out for ten simulated seconds.
		devices.handle(NMEA2000Commands.message(for: .down, windlassID: 1, destination: 255))
		_ = devices.statusFrames(heading: 0, dt: 10)
		var status = try #require(
			devices.statusFrames(heading: 0, dt: 0).first { $0.pgn == 128777 && $0.data[0] == 1 })
		let after = chainMetres(status.data)
		#expect(after > 20)  // started at 18 m
		#expect(status.data[4] & 0x03 == 2)  // deploying

		// Stop, then haul up: the chain shortens again.
		devices.handle(NMEA2000Commands.message(for: .off, windlassID: 1, destination: 255))
		devices.handle(NMEA2000Commands.message(for: .up, windlassID: 1, destination: 255))
		_ = devices.statusFrames(heading: 0, dt: 5)
		status = try #require(
			devices.statusFrames(heading: 0, dt: 0).first { $0.pgn == 128777 && $0.data[0] == 1 })
		#expect(chainMetres(status.data) < after)
		#expect(status.data[4] & 0x03 == 3)  // retrieving

		// Windlass 0 was never ordered around and stays put at 0 m, docked.
		let other = try #require(
			devices.statusFrames(heading: 0, dt: 0).first { $0.pgn == 128777 && $0.data[0] == 0 })
		#expect(chainMetres(other.data) == 0)
		#expect((other.data[4] >> 4) & 0x03 == 1)  // anchor docked
	}

	@Test func `the simulator session identifies the pilot and obeys it`() async throws {
		let session = NMEASimulator.session(
			route: .presets[0], speedKnots: 6, updateInterval: .milliseconds(50))
		#expect(session.isTransmitCapable)

		let consumer = Task {
			for try await _ in session.frames { try Task.checkCancellation() }
		}
		// Wait for the first claims to reach the session's directory.
		for _ in 0..<40 where session.autopilot() == nil {
			try await Task.sleep(for: .milliseconds(50))
		}
		let pilot = try #require(session.autopilot())
		#expect(pilot.brand == .raymarineEvolution)
		try await session.send(.engage)
		try await session.send(WindlassCommand.down, windlassID: 0)
		consumer.cancel()
	}

	private func headingDegrees(_ d: [UInt8]) -> Double {
		Double(UInt16(d[3]) | UInt16(d[4]) << 8) * 1e-4 * 180 / .pi
	}

	private func chainMetres(_ d: [UInt8]) -> Double {
		Double(UInt16(d[1]) | UInt16(d[2]) << 8) / 10
	}
}
