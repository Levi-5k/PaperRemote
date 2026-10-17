#include "../include/descriptor_lease.h"
#include "../include/reference_lifecycle.h"
#include <cassert>
#include <cstdio>
#include <string>

using namespace paper_board;

struct Upload {
    uint16_t owner = UINT16_MAX;
    uint32_t lastActivity = 0;
    std::string bytes;
};
struct Storage {
    bool mountInitially = false, formatSucceeds = true;
    unsigned mounts = 0, formats = 0;
    bool begin(bool formatOnFailure) {
        assert(!formatOnFailure);
        ++mounts;
        return mountInitially || (formats && formatSucceeds);
    }
    bool format() { ++formats; return formatSucceeds; }
};

static void uploadTests() {
    Upload upload;
    upload.owner = 12;
    upload.lastActivity = 100;
    upload.bytes = "incomplete JSON";
    int notifications = 0;
    auto notify = [&](uint16_t owner) { assert(owner == 12); ++notifications; };
    // No packet processing occurs between these independent main-loop polls.
    assert(!expireIdleUpload(upload, 30099, notify));
    assert(upload.bytes == "incomplete JSON");
    assert(expireIdleUpload(upload, 30100, notify));
    assert(upload.owner == UINT16_MAX && upload.bytes.empty() && notifications == 1);
    assert(!expireIdleUpload(upload, 100000, notify) && notifications == 1);
    upload.owner = 12;
    upload.lastActivity = UINT32_MAX - 99;
    assert(!expireIdleUpload(upload, 29899, notify));
    assert(expireIdleUpload(upload, 29900, notify) && notifications == 2);
    upload.owner = 12;
    upload.lastActivity = 100;
    upload.lastActivity = 29000; // Actual traffic extends only the idle deadline.
    assert(!expireIdleUpload(upload, 30100, notify));
    assert(expireIdleUpload(upload, 59000, notify));
}
static void storageTests() {
    unsigned warnings = 0;
    auto warning = [&](const char*) { ++warnings; };
    Storage corrupt;
    assert(!mountReferenceStorage(corrupt, false, warning));
    assert(corrupt.mounts == 1 && corrupt.formats == 0 && warnings == 1);
    Storage valid;
    valid.mountInitially = true;
    assert(mountReferenceStorage(valid, false, warning));
    assert(valid.mounts == 1 && valid.formats == 0 && warnings == 1);
    Storage provision;
    assert(mountReferenceStorage(provision, true, warning));
    assert(provision.mounts == 2 && provision.formats == 1 && warnings == 3);
    Storage validOptIn;
    validOptIn.mountInitially = true;
    assert(mountReferenceStorage(validOptIn, true, warning));
    assert(validOptIn.mounts == 1 && validOptIn.formats == 0 && warnings == 3);
    Storage failed;
    failed.formatSucceeds = false;
    assert(!mountReferenceStorage(failed, true, warning));
    assert(failed.mounts == 1 && failed.formats == 1 && warnings == 5);
}
static void descriptorTests() {
    DescriptorLease lease;
    assert(!lease.read(1, 0)); // An explicit offset-zero claim is required.
    assert(!lease.select(1, 512, 0));
    assert(lease.select(1, 0, 0));
    std::string cache = "owner first slice";
    const std::string before = cache;
    auto competingRead = [&](uint16_t handle, uint32_t offset, uint32_t now) {
        if (!lease.select(handle, offset, now)) return false;
        if (!lease.read(handle, now)) return false;
        cache = "replacement slice";
        return true;
    };
    assert(!competingRead(2, 0, 100));
    assert(cache == before && lease.owner() == 1 && lease.offset() == 0);
    assert(lease.read(1, 200));
    assert(lease.select(1, 512, 300));
    assert(lease.read(1, 301));
    // A final short nonempty slice must stay leased while Read Blob can continue.
    assert(!competingRead(2, 0, 302));
    assert(lease.owner() == 1);
    assert(lease.select(1, 900, 303));
    assert(lease.read(1, 304));
    lease.eof(1); // Callback has first replaced shared storage with an empty value.
    assert(lease.select(2, 0, 305));
    lease.disconnected(1);
    assert(lease.owner() == 2); // A different peer's disconnect cannot release the lease.
    lease.disconnected(2);
    assert(lease.select(3, 0, UINT32_MAX - 99));
    assert(lease.expire(29899) == DescriptorLease::noOwner);
    assert(lease.expire(29900) == 3);
    assert(!lease.select(4, 0, 29901)); // Expiry is not an unsafe immediate handoff.
    assert(!lease.select(3, 0, 29901));
    assert(!lease.read(3, 29901));
    lease.disconnected(3);
    assert(lease.select(4, 0, 29902));
    assert(lease.read(4, 29903));
    assert(lease.expire(59902) == DescriptorLease::noOwner);
    assert(lease.expire(59903) == 4);
}
int main() {
    uploadTests();
    storageTests();
    descriptorTests();
    puts("Reference idle upload expiry, non-destructive storage, and descriptor lease tests passed");
}
