#if os(Windows)
	internal import CCurl
	internal import Foundation
	import WinSDK

	// MARK: - Global initialisation

	/// One-time libcurl global initialisation (`static let` is thread-safe).
	enum CurlGlobal {
		static let initialized: Bool = boattools_curl_global_init() == CURLE_OK
	}

	/// Human-readable message for a libcurl result code.
	func curlMessage(_ code: CURLcode) -> String {
		guard let message = curl_easy_strerror(code) else { return "CURLcode \(code.rawValue)" }
		return String(cString: message)
	}

	/// Blocks until the socket is readable/writable or the timeout elapses.
	/// Used to back off between `CURLE_AGAIN` results without spinning.
	func curlWaitSocket(_ socket: curl_socket_t, forRead: Bool, timeoutMilliseconds: Int32) {
		var descriptor = WSAPOLLFD(
			fd: socket,
			events: Int16(forRead ? POLLRDNORM : POLLWRNORM),
			revents: 0)
		_ = WSAPoll(&descriptor, 1, timeoutMilliseconds)
	}

	// MARK: - CurlConnectionState

	/// Shared mutable state of one curl-backed connection (TCP or WebSocket).
	///
	/// libcurl forbids using one easy handle from several threads at once; the
	/// lock serialises every call on the handle between the reader thread and
	/// the sending caller. `@unchecked Sendable` is justified by that lock —
	/// no member is touched outside it.
	final class CurlConnectionState: @unchecked Sendable {
		private let lock = NSLock()
		private let handle: UnsafeMutableRawPointer
		private let headerList: UnsafeMutablePointer<curl_slist>?
		private var closed = false

		/// The connection's socket, for `WSAPoll` waits (safe to use unlocked —
		/// after `close()` the poll just reports an invalid descriptor).
		let socket: curl_socket_t

		init(
			handle: UnsafeMutableRawPointer,
			socket: curl_socket_t,
			headerList: UnsafeMutablePointer<curl_slist>? = nil
		) {
			self.handle = handle
			self.socket = socket
			self.headerList = headerList
		}

		/// Runs one libcurl call on the handle under the lock.
		/// Returns `nil` once the connection has been closed.
		func withHandle<T>(_ body: (UnsafeMutableRawPointer) -> T) -> T? {
			lock.lock()
			defer { lock.unlock() }
			guard !closed else { return nil }
			return body(handle)
		}

		/// Closes the connection and releases the easy handle. Idempotent.
		func close() {
			lock.lock()
			defer { lock.unlock() }
			guard !closed else { return }
			closed = true
			curl_easy_cleanup(handle)
			curl_slist_free_all(headerList)
		}
	}

#endif  // os(Windows)
