#include <dns_sd.h>

// Function-pointer typedefs for runtime loading via dlopen/dlsym.
//
// We never call these symbols directly from Swift — instead we look them up
// at runtime so the binary runs even when libdns_sd.so isn't installed (e.g.
// a user who didn't `apt install libavahi-compat-libdnssd1`). The CLI then
// reports the missing dependency with the install command.

typedef DNSServiceErrorType (DNSSD_API *PFN_DNSServiceCreateConnection)(
    DNSServiceRef *sdRef);

typedef DNSServiceErrorType (DNSSD_API *PFN_DNSServiceBrowse)(
    DNSServiceRef *sdRef,
    DNSServiceFlags flags,
    uint32_t interfaceIndex,
    const char *regtype,
    const char *domain,
    DNSServiceBrowseReply callBack,
    void *context);

typedef DNSServiceErrorType (DNSSD_API *PFN_DNSServiceResolve)(
    DNSServiceRef *sdRef,
    DNSServiceFlags flags,
    uint32_t interfaceIndex,
    const char *name,
    const char *regtype,
    const char *domain,
    DNSServiceResolveReply callBack,
    void *context);

typedef DNSServiceErrorType (DNSSD_API *PFN_DNSServiceProcessResult)(
    DNSServiceRef sdRef);

typedef void (DNSSD_API *PFN_DNSServiceRefDeallocate)(DNSServiceRef sdRef);

typedef int  (DNSSD_API *PFN_DNSServiceRefSockFD)(DNSServiceRef sdRef);

typedef const void * (DNSSD_API *PFN_TXTRecordGetValuePtr)(
    uint16_t txtLen,
    const void *txtRecord,
    const char *key,
    uint8_t *valueLen);
