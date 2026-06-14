#ifndef BOATTOOLS_CCURL_SHIM_H
#define BOATTOOLS_CCURL_SHIM_H

/* libcurl ≥ 8.0 built with the `websockets` feature is required, as a static
 * library so boattools.exe is self-contained (vcpkg:
 * `vcpkg install curl[websockets]:x64-windows-static-md`).
 * curl/curl.h includes curl/websockets.h since 7.86. */

/* Without this the headers declare the API __declspec(dllimport) and the
 * linker looks for __imp_curl_* symbols that a static libcurl does not have. */
#ifndef CURL_STATICLIB
#define CURL_STATICLIB
#endif

#include <curl/curl.h>

/* curl_easy_setopt and curl_easy_getinfo are C variadic functions, which Swift
 * cannot call. These typed wrappers cover the option families used by the
 * Swift transports. */

static inline CURLcode boattools_curl_setopt_long(CURL *handle, CURLoption option, long value) {
    return curl_easy_setopt(handle, option, value);
}

static inline CURLcode boattools_curl_setopt_string(CURL *handle, CURLoption option,
                                                    const char *value) {
    return curl_easy_setopt(handle, option, value);
}

static inline CURLcode boattools_curl_setopt_pointer(CURL *handle, CURLoption option, void *value) {
    return curl_easy_setopt(handle, option, value);
}

static inline CURLcode boattools_curl_setopt_offset(CURL *handle, CURLoption option,
                                                    curl_off_t value) {
    return curl_easy_setopt(handle, option, value);
}

typedef size_t (*boattools_curl_write_callback)(char *, size_t, size_t, void *);

static inline CURLcode boattools_curl_setopt_write_function(CURL *handle, CURLoption option,
                                                            boattools_curl_write_callback value) {
    return curl_easy_setopt(handle, option, value);
}

static inline CURLcode boattools_curl_getinfo_long(CURL *handle, CURLINFO info, long *value) {
    return curl_easy_getinfo(handle, info, value);
}

static inline CURLcode boattools_curl_getinfo_socket(CURL *handle, CURLINFO info,
                                                     curl_socket_t *value) {
    return curl_easy_getinfo(handle, info, value);
}

/* CURL_GLOBAL_ALL and the CURLWS_* flags are function-like / shifted macros,
 * which ClangImporter does not surface to Swift — re-export them as typed
 * constants. */

static inline CURLcode boattools_curl_global_init(void) {
    return curl_global_init(CURL_GLOBAL_ALL);
}

static const int boattools_curlws_text = CURLWS_TEXT;
static const int boattools_curlws_binary = CURLWS_BINARY;
static const int boattools_curlws_cont = CURLWS_CONT;
static const int boattools_curlws_close = CURLWS_CLOSE;

#endif /* BOATTOOLS_CCURL_SHIM_H */
