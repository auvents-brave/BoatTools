import Foundation

#if canImport(Darwin)

	/// Looks a label up in the kit's own resource bundle.
	///
	/// - Parameter key: the English source string, also the catalogue key.
	/// - Returns: the label in the current language.
	func localizedLabel(_ key: String.LocalizationValue) -> String {
		String(localized: key, bundle: .module)
	}

#else

	/// Returns the label unchanged.
	///
	/// Foundation off Darwin has neither `String(localized:)` nor
	/// `String.LocalizationValue`, so there is nothing to look a key up in — and
	/// a headless tool on Linux or Windows wants the English source anyway. The
	/// signature takes a plain `String` so the call sites, which pass literals,
	/// compile either way.
	///
	/// - Parameter key: the English source string.
	/// - Returns: that same string.
	func localizedLabel(_ key: String) -> String { key }

#endif
