#pragma once

#include <cmath>
#include <cstdint>

namespace geometric_snake {

constexpr int kMaxNodes = 1200;
constexpr int kMaxSnakes = 80;
constexpr int kBodyNodes = 12;
constexpr int kMaxFaces = 600;
constexpr int kSnakeSpacing = kBodyNodes + 3;
constexpr float kEdge = 22.0f;
constexpr float kMargin = 8.0f;
// Eight substeps per edge; the display driver determines the actual frame rate.
constexpr float kStep = 0.125f;
constexpr int16_t kNone = -1;

struct Point { float x; float y; };
struct Node {
    Point point;
    int16_t neighbors[3];
    int16_t owner;
    int16_t gridX;
    int16_t gridY;
    uint8_t degree;
};
struct Snake {
    int16_t body[kBodyNodes]; // Tail to head, adjacent honeycomb vertices.
    int16_t next;
};

// Bounded storage; keep this off the ESP32 task stack. Each route and
// in-flight edge endpoint stays exclusively owned until the tail leaves it.
struct Scene {
    Node nodes[kMaxNodes];
    Snake snakes[kMaxSnakes];
    int16_t faces[kMaxFaces][6];
    int16_t successor[kMaxNodes];
    int16_t route[kMaxNodes];
    int faceCount = 0;
    int routeLength = 0;
    int nodeCount = 0;
    int snakeCount = 0;
    float progress = 0;
    uint32_t randomState = 1;

    uint32_t random() {
        randomState ^= randomState << 13;
        randomState ^= randomState >> 17;
        randomState ^= randomState << 5;
        return randomState;
    }

    int16_t vertex(int x, int y) {
        for (int index = 0; index < nodeCount; ++index) {
            if (nodes[index].gridX == x && nodes[index].gridY == y) return index;
        }
        if (nodeCount == kMaxNodes) return kNone;
        Node& node = nodes[nodeCount];
        node.point = {kMargin + x * kEdge * 0.5f,
                      kMargin + y * kEdge * 0.86602540378f};
        node.gridX = x;
        node.gridY = y;
        node.degree = 0;
        node.owner = kNone;
        for (auto& neighbor : node.neighbors) neighbor = kNone;
        return nodeCount++;
    }

    void connect(int16_t a, int16_t b) {
        if (a == kNone || b == kNone) return;
        Node& node = nodes[a];
        for (int i = 0; i < node.degree; ++i) {
            if (node.neighbors[i] == b) return;
        }
        if (node.degree < 3) node.neighbors[node.degree++] = b;
    }

    void plan() {
        for (int id = 0; id < snakeCount; ++id) {
            Snake& snake = snakes[id];
            snake.next = successor[snake.body[kBodyNodes - 1]];
            nodes[snake.next].owner = id;
        }
    }

    // Grow a simple cycle by replacing one hexagon edge with its five-edge
    // detour. The four new vertices must be unused. This preserves closure and
    // forbids crossings, branches, dead ends and repeated vertices by construction.
    bool expandCycle(const int16_t* face) {
        int occupied = 0;
        for (int i = 0; i < 6; ++i) occupied += successor[face[i]] != kNone;
        if (occupied != 2) return false;
        for (int i = 0; i < 6; ++i) {
            const int j = (i + 1) % 6;
            int start, direction;
            if (successor[face[i]] == face[j]) {
                start = i;
                direction = -1;
            } else if (successor[face[j]] == face[i]) {
                start = j;
                direction = 1;
            } else {
                continue;
            }
            for (int step = 0; step < 5; ++step) {
                const int a = (start + direction * step + 12) % 6;
                const int b = (start + direction * (step + 1) + 12) % 6;
                successor[face[a]] = face[b];
            }
            return true;
        }
        return false;
    }

    void generateRoute() {
        for (int index = 0; index < nodeCount; ++index) successor[index] = kNone;
        // A seeded permutation changes the maze-like contour, but decisions
        // happen only during construction, never as a snake approaches a turn.
        for (int i = faceCount - 1; i > 0; --i) {
            const int j = random() % (i + 1);
            for (int corner = 0; corner < 6; ++corner) {
                const int16_t saved = faces[i][corner];
                faces[i][corner] = faces[j][corner];
                faces[j][corner] = saved;
            }
        }
        const int16_t start = faces[0][0];
        for (int i = 0; i < 6; ++i) successor[faces[0][i]] = faces[0][(i + 1) % 6];
        bool grew;
        do {
            grew = false;
            for (int i = 0; i < faceCount; ++i) grew |= expandCycle(faces[i]);
        } while (grew);
        routeLength = 0;
        int16_t vertex = start;
        do {
            route[routeLength++] = vertex;
            vertex = successor[vertex];
        } while (vertex != start && routeLength < kMaxNodes);
    }

    void reset(uint32_t seed, int width, int height) {
        randomState = seed == 0 ? 1 : seed;
        nodeCount = snakeCount = 0;
        faceCount = routeLength = 0;
        progress = 0;
        constexpr int dx[6] = {2, 1, -1, -2, -1, 1};
        constexpr int dy[6] = {0, 1, 1, 0, -1, -1};
        // Shared corners form a true degree-three honeycomb, not a rectangular
        // zigzag or a triangular grid of hexagon centers. The grid is invisible.
        for (int column = 0; ; ++column) {
            const int x = 2 + 3 * column;
            if (kMargin + (x + 2) * kEdge * 0.5f > width - kMargin) break;
            for (int row = 0; ; ++row) {
                const int y = 1 + 2 * row + column % 2;
                if (kMargin + (y + 1) * kEdge * 0.86602540378f > height - kMargin) break;
                if (faceCount == kMaxFaces || nodeCount + 6 > kMaxNodes) break;
                int16_t corners[6];
                for (int corner = 0; corner < 6; ++corner) {
                    corners[corner] = vertex(x + dx[corner], y + dy[corner]);
                }
                for (int corner = 0; corner < 6; ++corner) {
                    faces[faceCount][corner] = corners[corner];
                    connect(corners[corner], corners[(corner + 1) % 6]);
                    connect(corners[(corner + 1) % 6], corners[corner]);
                }
                ++faceCount;
            }
        }
        if (faceCount == 0) return;
        generateRoute();

        // Equal speed + at least three empty vertices per snake guarantees
        // every next reservation is free, including at the loop seam forever.
        snakeCount = routeLength / kSnakeSpacing;
        if (snakeCount > kMaxSnakes) snakeCount = kMaxSnakes;
        for (int id = 0; id < snakeCount; ++id) {
            Snake& snake = snakes[id];
            const int start = id * routeLength / snakeCount;
            for (int i = 0; i < kBodyNodes; ++i) {
                snake.body[i] = route[(start + i) % routeLength];
                nodes[snake.body[i]].owner = id;
            }
        }
        plan();
    }

    void advance() {
        progress += kStep;
        if (progress < 1.0f) return;
        progress = 0;
        for (int id = 0; id < snakeCount; ++id) {
            Snake& snake = snakes[id];
            if (snake.next == kNone) continue;
            nodes[snake.body[0]].owner = kNone;
            for (int i = 1; i < kBodyNodes; ++i) snake.body[i - 1] = snake.body[i];
            snake.body[kBodyNodes - 1] = snake.next;
            snake.next = kNone;
        }
        plan();
    }

    Point between(int16_t a, int16_t b, float t) const {
        const Point p = nodes[a].point;
        const Point q = nodes[b].point;
        return {p.x + (q.x - p.x) * t, p.y + (q.y - p.y) * t};
    }
};

template <typename Canvas>
void stroke(Canvas& canvas, Point a, Point b) {
    // Plain three-pixel lines. No head markers, beads, shapes or visible grid.
    const int x1 = std::lround(a.x), y1 = std::lround(a.y);
    const int x2 = std::lround(b.x), y2 = std::lround(b.y);
    canvas.drawLine(x1, y1, x2, y2, 0);
    canvas.drawLine(x1 + 1, y1, x2 + 1, y2, 0);
    canvas.drawLine(x1, y1 + 1, x2, y2 + 1, 0);
}

// One monochrome offscreen frame, with no per-segment display refreshes,
// dynamic allocation, trigonometry, or all-pairs collision checks.
template <typename Canvas>
void render(Canvas& canvas, const Scene& scene) {
    canvas.fillScreen(1);
    for (int id = 0; id < scene.snakeCount; ++id) {
        const Snake& snake = scene.snakes[id];
        const bool moving = snake.next != kNone;
        Point previous = moving
            ? scene.between(snake.body[0], snake.body[1], scene.progress)
            : scene.nodes[snake.body[0]].point;
        for (int i = 1; i < kBodyNodes; ++i) {
            const Point point = scene.nodes[snake.body[i]].point;
            stroke(canvas, previous, point);
            previous = point;
        }
        if (moving) {
            stroke(canvas, previous,
                   scene.between(snake.body[kBodyNodes - 1], snake.next, scene.progress));
        }
    }
}

}  // namespace geometric_snake