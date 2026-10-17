#pragma once
#include "board_driver.h"

namespace paper_board {
// Generic display/preview policy only. The deployed M5Paper renderer retains its legacy layout.
inline Rect genericControlRect(const Rect& viewport, unsigned columns, unsigned rows,
                               unsigned slot, unsigned columnSpan = 1, unsigned rowSpan = 1,
                               double previewGap = 2) {
    if (!validRect(viewport) || !columns || !rows || slot >= columns * rows ||
        !columnSpan || !rowSpan || !std::isfinite(previewGap) || previewGap < 0) return {};
    const unsigned column = slot % columns, row = slot / columns;
    if (column + columnSpan > columns || row + rowSpan > rows) return {};
    const double cellWidth = viewport.width * .92 / columns;
    const double cellHeight = viewport.height * .92 / rows;
    const double width = cellWidth * columnSpan, height = cellHeight * rowSpan;
    // At tiny simulated sizes, preserve a positive hit region rather than invert its bounds.
    const double gap = std::fmin(previewGap, std::fmin(width, height) / 2);
    return {viewport.x + viewport.width * .04 + column * cellWidth + gap / 2,
        viewport.y + viewport.height * .04 + row * cellHeight + gap / 2,
        width - gap, height - gap};
}
}
