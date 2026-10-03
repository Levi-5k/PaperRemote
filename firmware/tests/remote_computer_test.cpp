#include "../include/remote_computer.h"
#include <cassert>
#include <cstdio>
#include <utility>

struct Computer {
    char id[40] = {};
    char host[64] = {};
    uint16_t port = 43821;
    char token[80] = {};
};

struct Profile {
    Computer computers[2];
    size_t computerCount = 0;
    char macHost[64] = {};
    char macToken[80] = {};
};

struct Control {
    int kind = 0;
    char textComputerId[40] = {};
    struct Action { char computerId[40] = {}; } action;
};

int main() {
    using namespace remote_computer;
    Profile profile;
    assert(indexFor(profile, "") == missing);
    std::strcpy(profile.macHost, "mac.local");
    assert(indexFor(profile, "") == missing);
    std::strcpy(profile.macToken, "test-mac-token");
    assert(indexFor(profile, "") == legacy);
    assert(indexFor(profile, "removed-id") == missing);

    Computer& mac = profile.computers[0];
    Computer& windows = profile.computers[1];
    std::strcpy(mac.id, "0417550F-4E0C-4157-A7D0-080B824E88BF");
    std::strcpy(mac.host, "mac.local");
    std::strcpy(mac.token, "test-mac-token");
    std::strcpy(windows.id, "ed424ff4-d992-4092-8a08-fe2f22e0bed8");
    std::strcpy(windows.host, "windows.local");
    std::strcpy(windows.token, "test-windows-token");
    profile.computerCount = 2;
    // A Windows editor can rewrite legacy fields; it must not redirect the
    // default away from the first paired computer used by all modern editors.
    std::strcpy(profile.macHost, windows.host);
    std::strcpy(profile.macToken, windows.token);
    assert(indexFor(profile, "") == 0);
    assert(indexFor(profile, "0417550f-4e0c-4157-a7d0-080b824e88bf") == 0);
    assert(indexFor(profile, "ED424FF4-D992-4092-8A08-FE2F22E0BED8") == 1);
    assert(indexFor(profile, "removed-id") == missing);
    assert(!sameId(mac.id, "0417550f-4e0c-4157-a7d0-080b824e88b"));

    Control control;
    std::strcpy(control.action.computerId, mac.id);
    std::strcpy(control.textComputerId, windows.id);
    // Leftover now-playing text configuration cannot hijack a media button or
    // slider's state source; it must agree with the actual action target.
    for (int kind : {0, 1}) {
        control.kind = kind;
        assert(indexFor(profile, stateComputerId(control)) ==
            indexFor(profile, control.action.computerId));
    }
    // Genuine text boxes may intentionally read one computer and tap another.
    control.kind = 2;
    assert(indexFor(profile, stateComputerId(control)) == 1);
    control.textComputerId[0] = '\0';
    assert(indexFor(profile, stateComputerId(control)) == 0);
    std::strcpy(control.textComputerId, "removed-id");
    assert(indexFor(profile, stateComputerId(control)) == missing);

    assert(acceptsToken(&mac, "test-mac-token"));
    assert(!acceptsToken(&mac, "test-windows-token"));
    assert(!acceptsToken(&mac, ""));
    assert(!acceptsToken(&mac, nullptr));
    assert(!acceptsToken(static_cast<Computer*>(nullptr), "test-mac-token"));
    assert(acceptsResponse(&mac, "http://mac.local:43821/text-source", "test-mac-token"));
    assert(!acceptsResponse(&mac, "http://windows.local:43821/text-source", "test-mac-token"));
    assert(!acceptsResponse(&mac, "http://mac.local:43822/text-source", "test-mac-token"));
    assert(!acceptsResponse(&mac, "http://mac.local:43821/text-source", "test-windows-token"));
    // Same control ID, new target: old subscription pushes must no longer win.
    std::strcpy(control.action.computerId, windows.id);
    control.kind = 0;
    const Computer* retargeted = &profile.computers[indexFor(profile, stateComputerId(control))];
    assert(!acceptsToken(retargeted, "test-mac-token"));
    assert(acceptsToken(retargeted, "test-windows-token"));
    // Reordering the computer list must never redirect explicit UUID targets.
    std::swap(profile.computers[0], profile.computers[1]);
    assert(indexFor(profile, control.action.computerId) == 0);
    assert(indexFor(profile, "0417550f-4e0c-4157-a7d0-080b824e88bf") == 1);
    assert(indexFor(profile, "") == 0);
    std::puts("Remote computer routing tests passed");
}