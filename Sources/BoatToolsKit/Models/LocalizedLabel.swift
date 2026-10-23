import Foundation

/// Looks a label up in the kit's own resource bundle.
///
/// `String(localized:bundle:)` is Darwin-only: Foundation on Linux and Windows
/// offers no `bundle:` overload, and the kit builds for all three. Off Darwin
/// the English source stands, which is what a headless tool on those platforms
/// wants anyway.
///
/// - Parameter key: the English source string, also the catalogue key.
/// - Returns: the label in the current language, or the English source.
func localizedLabel(_ key: String.LocalizationValue) -> String {
	#if canImport(Darwin)
		String(localized: key, bundle: .module)
	#else
		String(localized: key)
	#endif
}
