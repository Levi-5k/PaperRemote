#include "../include/remote_network_queue.h"
#include <assert.h>
#include <stdio.h>

struct Request {
    bool slider = false;
    uint32_t profileRevision = 1;
    char controlId[16] = "volume";
    char url[32] = "http://computer/action";
    int value = 0;
};

int main() {
    using namespace remote_network;
    assert(laneFor("macMedia", false) == Lane::interactive);
    assert(laneFor("openBuilds", false) == Lane::interactive);
    assert(laneFor("netHomeClimate", false) == Lane::climate);
    assert(laneFor("netHomeFan", false) == Lane::climate);
    assert(laneFor("deviceLog", true) == Lane::background);
    assert(responseTimeoutMs(Lane::background, true) == 15000);
    assert(responseTimeoutMs(Lane::climate, false) == 35000);

    WorkQueue<Request, 3> queue;
    Request request, received;
    request.slider = true;
    assert(!queue.hasWork());
    assert(queue.enqueue(request));
    request.value = 25;
    assert(queue.enqueue(request));
    assert(queue.take(received) && received.value == 25);
    assert(queue.hasWork()); // In-flight work must prevent deep sleep.
    assert(!queue.take(received));
    queue.finish();
    assert(!queue.hasWork());

    assert(queue.enqueue(request));
    strcpy(request.controlId, "brightness");
    request.value = 50;
    assert(queue.enqueue(request));
    assert(queue.take(received) && strcmp(received.controlId, "volume") == 0);
    queue.finish();
    assert(queue.take(received) && strcmp(received.controlId, "brightness") == 0);
    queue.finish();

    // A button is an ordering barrier; a later slider update cannot replace an
    // earlier value across it. Coalescing still works when the queue is full.
    request.value = 1;
    assert(queue.enqueue(request));
    request.slider = false;
    assert(queue.enqueue(request));
    request.slider = true;
    request.value = 2;
    assert(queue.enqueue(request));
    request.value = 3;
    assert(queue.enqueue(request));
    request.profileRevision = 2;
    assert(!queue.enqueue(request));
    assert(queue.take(received) && received.slider && received.value == 1);
    queue.finish();
    assert(queue.take(received) && !received.slider);
    queue.finish();
    assert(queue.take(received) && received.slider && received.value == 3);
    queue.finish();
    assert(!queue.hasWork());

    // A slow lane completing after a newer interactive request must still be
    // considered active; sequence-number high-water marks cannot represent it.
    WorkQueue<Request, 3> slow;
    assert(slow.enqueue(request) && slow.take(received));
    assert(queue.enqueue(request) && queue.take(received));
    queue.finish();
    assert(!queue.hasWork() && slow.hasWork());
    slow.finish();
    assert(!slow.hasWork());

    // Distinct targets/revisions must never coalesce. Exercise ring wraparound.
    for (int iteration = 0; iteration < 1000; ++iteration) {
        request.value = iteration;
        assert(queue.enqueue(request));
        ++request.profileRevision;
        assert(queue.enqueue(request));
        assert(queue.take(received) && received.profileRevision == request.profileRevision - 1);
        queue.finish();
        assert(queue.take(received) && received.profileRevision == request.profileRevision);
        queue.finish();
    }
    assert(queue.enqueue(request));
    strcpy(request.url, "http://other/action");
    assert(queue.enqueue(request));
    assert(queue.take(received) && strcmp(received.url, "http://computer/action") == 0);
    queue.finish();
    assert(queue.take(received) && strcmp(received.url, request.url) == 0);
    queue.finish();
    puts("Remote network queue tests passed");
}