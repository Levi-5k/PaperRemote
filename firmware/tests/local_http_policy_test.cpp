#include "../include/local_http_policy.h"
#include <assert.h>
#include <stdio.h>

int main() {
    using namespace local_http;

    assert(isPrivateIPv4(10, 0));
    assert(isPrivateIPv4(127, 0));
    assert(isPrivateIPv4(169, 254));
    assert(isPrivateIPv4(172, 16));
    assert(isPrivateIPv4(172, 31));
    assert(isPrivateIPv4(192, 168));
    assert(!isPrivateIPv4(172, 15));
    assert(!isPrivateIPv4(172, 32));
    assert(!isPrivateIPv4(8, 8));

    assert(isLocalHostname("switch.local"));
    assert(!isLocalHostname("local"));
    assert(!isLocalHostname("switch.local.example.com"));

    assert(isAllowedMethod("GET"));
    assert(isAllowedMethod("POST"));
    assert(!isAllowedMethod("DELETE"));

    assert(isAllowedPath("/relay/0?turn=toggle"));
    assert(!isAllowedPath("relay/0"));
    assert(!isAllowedPath("/path#fragment"));
    assert(!isAllowedPath("/path\r\nInjected: true"));
    assert(!isAllowedPath("http://example.com"));

    puts("Local HTTP policy tests passed");
}