#if os(Windows)
	internal import CCurl
	internal import Foundation

	// MARK: - CurlHTTPTransport

	/// libcurl-backed ``HTTPTransport`` for Windows.
	///
	/// One easy handle per request, executed on a detached thread (the easy
	/// interface is blocking). Nothing is pooled, so ``shutdown()`` is a no-op.
	/// TLS uses the Schannel backend of the vcpkg libcurl build, which trusts
	/// the Windows certificate store.
	final class CurlHTTPTransport: HTTPTransport {

		func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
			guard CurlGlobal.initialized else {
				throw TransportError.connect("libcurl global initialisation failed")
			}
			return try await withCheckedThrowingContinuation { continuation in
				Thread.detachNewThread {
					continuation.resume(with: Result { try Self.perform(request) })
				}
			}
		}

		func shutdown() async throws {
			// No pooled resources.
		}

		// MARK: Blocking request

		/// Accumulates the response while libcurl delivers it to the C callbacks.
		private final class ResponseAccumulator {
			var body: [UInt8] = []
			var headerLines: [String] = []
			var bodyLimit = Int.max
		}

		private static func perform(_ request: HTTPRequest) throws -> HTTPResponse {
			guard let handle = curl_easy_init() else {
				throw TransportError.connect("curl_easy_init failed")
			}
			defer { curl_easy_cleanup(handle) }

			_ = boattools_curl_setopt_string(handle, CURLOPT_URL, request.url)
			_ = boattools_curl_setopt_string(handle, CURLOPT_CUSTOMREQUEST, request.method)
			_ = boattools_curl_setopt_long(handle, CURLOPT_FOLLOWLOCATION, 1)
			let timeoutMilliseconds =
				request.timeout.components.seconds * 1000
				+ request.timeout.components.attoseconds / 1_000_000_000_000_000
			_ = boattools_curl_setopt_long(
				handle, CURLOPT_TIMEOUT_MS, CLong(clamping: timeoutMilliseconds))

			var headerList: UnsafeMutablePointer<curl_slist>?
			for header in request.headers {
				headerList = curl_slist_append(headerList, "\(header.name): \(header.value)")
			}
			if let headerList {
				_ = boattools_curl_setopt_pointer(
					handle, CURLOPT_HTTPHEADER, UnsafeMutableRawPointer(headerList))
			}
			defer { curl_slist_free_all(headerList) }

			if let body = request.body {
				// COPYPOSTFIELDS copies the bytes during the call, so the
				// pointer does not need to outlive this scope. The size must be
				// set first for binary-safe bodies.
				_ = boattools_curl_setopt_offset(
					handle, CURLOPT_POSTFIELDSIZE_LARGE, curl_off_t(body.count))
				body.withUnsafeBytes { raw in
					_ = boattools_curl_setopt_pointer(
						handle, CURLOPT_COPYPOSTFIELDS,
						UnsafeMutableRawPointer(mutating: raw.baseAddress))
				}
			}

			let accumulator = ResponseAccumulator()
			accumulator.bodyLimit = request.maxResponseBytes
			let accumulatorPointer = Unmanaged.passUnretained(accumulator).toOpaque()

			// C callbacks cannot capture context — the accumulator travels
			// through the libcurl userdata pointer.
			let writeBody: boattools_curl_write_callback = { pointer, size, count, userdata in
				guard let pointer, let userdata else { return 0 }
				let accumulator = Unmanaged<ResponseAccumulator>
					.fromOpaque(userdata).takeUnretainedValue()
				let total = size * count
				guard accumulator.body.count + total <= accumulator.bodyLimit else { return 0 }
				accumulator.body.append(
					contentsOf: UnsafeRawBufferPointer(start: pointer, count: total)
						.bindMemory(to: UInt8.self))
				return total
			}
			let writeHeader: boattools_curl_write_callback = { pointer, size, count, userdata in
				guard let pointer, let userdata else { return 0 }
				let accumulator = Unmanaged<ResponseAccumulator>
					.fromOpaque(userdata).takeUnretainedValue()
				let total = size * count
				let bytes = UnsafeRawBufferPointer(start: pointer, count: total)
				accumulator.headerLines.append(String(decoding: bytes, as: UTF8.self))
				return total
			}
			_ = boattools_curl_setopt_write_function(handle, CURLOPT_WRITEFUNCTION, writeBody)
			_ = boattools_curl_setopt_pointer(handle, CURLOPT_WRITEDATA, accumulatorPointer)
			_ = boattools_curl_setopt_write_function(handle, CURLOPT_HEADERFUNCTION, writeHeader)
			_ = boattools_curl_setopt_pointer(handle, CURLOPT_HEADERDATA, accumulatorPointer)

			let result = withExtendedLifetime(accumulator) { curl_easy_perform(handle) }
			guard result == CURLE_OK else {
				throw TransportError.receive(curlMessage(result))
			}

			var status: CLong = 0
			_ = boattools_curl_getinfo_long(handle, CURLINFO_RESPONSE_CODE, &status)

			return HTTPResponse(
				status: UInt(status),
				headers: Self.parseHeaders(accumulator.headerLines),
				body: accumulator.body)
		}

		/// Splits raw `Name: value` header lines, skipping status lines and the
		/// blank terminator. With redirects or `100 Continue` several header
		/// blocks arrive; later blocks simply append.
		private static func parseHeaders(_ lines: [String]) -> [(name: String, value: String)] {
			var headers: [(name: String, value: String)] = []
			for line in lines {
				let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
				guard !trimmed.isEmpty, !trimmed.hasPrefix("HTTP/") else { continue }
				guard let colon = trimmed.firstIndex(of: ":") else { continue }
				let name = String(trimmed[..<colon])
				let value = trimmed[trimmed.index(after: colon)...]
					.trimmingCharacters(in: .whitespaces)
				headers.append((name: name, value: value))
			}
			return headers
		}
	}

#endif  // os(Windows)
