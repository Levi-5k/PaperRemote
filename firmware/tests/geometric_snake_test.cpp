#include "geometric_snake.h"

#include <cassert>
#include <chrono>
#include <fstream>
#include <iostream>
#include <vector>

namespace {

constexpr int kWidth = 540;
constexpr int kHeight = 960;

float separation(geometric_snake::Point a, geometric_snake::Point b) {
    return std::hypot(a.x - b.x, a.y - b.y);
}

struct TestCanvas {
    std::ostream* svg = nullptr;
    const geometric_snake::Scene* scene = nullptr;
    int blackPrimitives = 0;
    int snakeId = 0;
    int snakeLines = 0;
    bool rasterCheck = false;
    std::vector<int16_t> pixels = std::vector<int16_t>(kWidth * kHeight, -1);

    void check(int x, int y) {
        assert(x >= 0 && x < kWidth);
        assert(y >= 0 && y < kHeight);
    }

    void fillScreen(int color) {
        assert(color == 1);
        snakeId = snakeLines = 0;
        if (rasterCheck) std::fill(pixels.begin(), pixels.end(), -1);
        if (svg) *svg << "<rect width='540' height='960' fill='white'/>\n";
    }

    void drawLine(int x1, int y1, int x2, int y2, int color) {
        check(x1, y1);
        check(x2, y2);
        assert(color == 0);
        ++blackPrimitives;
        if (svg) *svg << "<path d='M " << x1 << ' ' << y1 << " L " << x2 << ' ' << y2
                      << "' stroke='black'/>\n";
        if (rasterCheck) {
            // Verify actual three-pixel strokes do not touch other snakes,
            // including fractional positions between reserved grid vertices.
            const int dx = std::abs(x2 - x1), sx = x1 < x2 ? 1 : -1;
            const int dy = -std::abs(y2 - y1), sy = y1 < y2 ? 1 : -1;
            int error = dx + dy;
            while (true) {
                int16_t& owner = pixels[y1 * kWidth + x1];
                assert(owner == -1 || owner == snakeId);
                owner = snakeId;
                if (x1 == x2 && y1 == y2) break;
                const int twice = 2 * error;
                if (twice >= dy) { error += dy; x1 += sx; }
                if (twice <= dx) { error += dx; y1 += sy; }
            }
        }
        assert(scene != nullptr && snakeId < scene->snakeCount);
        const int expected = 3 * (geometric_snake::kBodyNodes - 1 +
            (scene->snakes[snakeId].next != geometric_snake::kNone ? 1 : 0));
        if (++snakeLines == expected) { ++snakeId; snakeLines = 0; }
    }
};

bool adjacent(const geometric_snake::Scene& scene, int a, int b) {
    assert(a >= 0 && a < scene.nodeCount && b >= 0 && b < scene.nodeCount);
    for (int i = 0; i < scene.nodes[a].degree; ++i) {
        if (scene.nodes[a].neighbors[i] == b) return true;
    }
    return false;
}

void validateRoutes(const geometric_snake::Scene& scene) {
    using namespace geometric_snake;
    int16_t owners[kMaxNodes];
    std::fill(owners, owners + kMaxNodes, kNone);
    for (int id = 0; id < scene.snakeCount; ++id) {
        const Snake& snake = scene.snakes[id];
        for (int i = 0; i < kBodyNodes; ++i) {
            const int index = snake.body[i];
            assert(index >= 0 && index < scene.nodeCount);
            assert(owners[index] == kNone); // No self-intersections either.
            owners[index] = id;
            if (i > 0) assert(adjacent(scene, snake.body[i - 1], index));
        }
        if (snake.next != kNone) {
            assert(adjacent(scene, snake.body[kBodyNodes - 1], snake.next));
            assert(owners[snake.next] == kNone);
            owners[snake.next] = id;
        }
    }
    for (int index = 0; index < scene.nodeCount; ++index) {
        assert(owners[index] == scene.nodes[index].owner);
    }
    assert(scene.progress >= 0 && scene.progress < 1);
}

uint32_t routeHash(const geometric_snake::Scene& scene) {
    uint32_t hash = 2166136261u;
    for (int id = 0; id < scene.snakeCount; ++id) {
        for (int node : scene.snakes[id].body) hash = (hash ^ node) * 16777619u;
    }
    return hash;
}

}  // namespace

int main(int argc, char** argv) {
    using namespace geometric_snake;
    static Scene scene;
    static Scene repeat;
    static Scene referenceGrid;
    referenceGrid.reset(42, kWidth, kHeight);
    TestCanvas canvas;
    canvas.scene = &scene;
    int minimumPopulation = kMaxSnakes;
    int minimumMoving = kMaxSnakes;
    uint32_t previousSeedHash = 0;
    const auto started = std::chrono::steady_clock::now();
    for (uint32_t seed = 0; seed < 24; ++seed) {
        scene.reset(seed * 7919 + 42, kWidth, kHeight);
        repeat.reset(seed * 7919 + 42, kWidth, kHeight);
        assert(routeHash(scene) == routeHash(repeat));
        assert(routeHash(scene) != previousSeedHash);
        previousSeedHash = routeHash(scene);
        assert(scene.nodeCount > 700 && scene.nodeCount < kMaxNodes);
        assert(scene.snakeCount >= 35 && scene.snakeCount <= kMaxSnakes);
        minimumPopulation = std::min(minimumPopulation, scene.snakeCount);
        // Routing must not change the existing 22px, degree-three honeycomb.
        assert(scene.nodeCount == 798);
        bool onRoute[kMaxNodes] = {};
        for (int i = 0; i < scene.routeLength; ++i) {
            const int node = scene.route[i];
            assert(node >= 0 && node < scene.nodeCount && !onRoute[node]);
            onRoute[node] = true;
            assert(scene.successor[node] == scene.route[(i + 1) % scene.routeLength]);
            assert(adjacent(scene, node, scene.successor[node]));
        }
        assert(scene.routeLength >= scene.snakeCount * kSnakeSpacing);
        // Every graph edge is exactly one hexagon side: 0 or +/-60 degrees.
        for (int index = 0; index < scene.nodeCount; ++index) {
            const Node& node = scene.nodes[index];
            const Node& original = referenceGrid.nodes[index];
            assert(node.point.x == original.point.x && node.point.y == original.point.y);
            assert(node.gridX == original.gridX && node.gridY == original.gridY);
            assert(node.degree == original.degree);
            for (int i = 0; i < 3; ++i) assert(node.neighbors[i] == original.neighbors[i]);
            assert(node.degree >= 2 && node.degree <= 3);
            for (int i = 0; i < node.degree; ++i) {
                const int next = node.neighbors[i];
                assert(adjacent(scene, next, index));
                const Point other = scene.nodes[next].point;
                assert(std::fabs(separation(node.point, other) - kEdge) < 0.001f);
                const float angle = std::atan2(other.y - node.point.y, other.x - node.point.x);
                const float sixths = angle / (3.14159265359f / 3);
                assert(std::fabs(sixths - std::round(sixths)) < 0.001f);
            }
        }
        // Traverse more than a complete circuit to cover the closing seam.
        for (int frame = 0; frame < 8000; ++frame) {
            validateRoutes(scene);
            int moving = 0;
            for (int id = 0; id < scene.snakeCount; ++id) {
                moving += scene.snakes[id].next != kNone;
            }
            minimumMoving = std::min(minimumMoving, moving);
            assert(moving == scene.snakeCount); // Every snake always has a next edge.
            canvas.rasterCheck = frame % 400 < 8;
            render(canvas, scene);
            assert(canvas.snakeId == scene.snakeCount && canvas.snakeLines == 0);
            repeat = scene;
            scene.advance();
            const bool completedStep = repeat.progress + kStep >= 1.0f;
            for (int id = 0; id < scene.snakeCount; ++id) {
                const Snake& before = repeat.snakes[id];
                const Snake& after = scene.snakes[id];
                for (int node = 0; node < kBodyNodes; ++node) {
                    const int expected = completedStep && before.next != kNone
                        ? (node + 1 < kBodyNodes ? before.body[node + 1] : before.next)
                        : before.body[node];
                    assert(after.body[node] == expected); // No reversal/teleport.
                }
            }
        }
    }
    assert(canvas.blackPrimitives > 0);
    scene.reset(0, 1, 1);
    assert(scene.nodeCount == 0 && scene.snakeCount == 0);
    scene.advance();

    if (argc == 2) {
        std::ofstream preview(argv[1]);
        assert(preview.is_open());
        preview << "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1640 960'>\n";
        canvas.svg = &preview;
        canvas.rasterCheck = true;
        scene.reset(42, kWidth, kHeight);
        for (int frame = 0; frame < 3; ++frame) {
            preview << "<g transform='translate(" << frame * 550 << " 0)'>\n";
            render(canvas, scene);
            preview << "</g>\n";
            for (int step = 0; step < 32; ++step) scene.advance();
        }
        preview << "</svg>\n";
    }
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - started).count();
    std::cout << "PASS: 24 random seeds, 192000 frames; exclusive routes, unchanged hex grid, "
              << "forward-only motion, plain-line rendering and raster collision checks. Minimum population: "
              << minimumPopulation << "; minimum moving: " << minimumMoving
              << "; simulation bytes: " << sizeof(Scene) << "; host test time: " << elapsed << "ms.\n";
}