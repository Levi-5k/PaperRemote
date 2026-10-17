namespace PaperGIF.Windows.Core.Models;

public static class DevicePreviewGeometry
{
    public static DeviceRect GenericGrid(DeviceRect viewport) => new(
        viewport.X + viewport.Width * 0.04, viewport.Y + viewport.Height * 0.04,
        viewport.Width * 0.92, viewport.Height * 0.92);

    public static DeviceRect ControlFrame(DeviceRect grid, int columns, int rows,
        int slot, int width, int height)
    {
        if (columns < 1 || rows < 1 || slot < 0 || slot >= columns * rows ||
            width < 1 || height < 1 || slot % columns + width > columns || slot / columns + height > rows)
            throw new ArgumentOutOfRangeException(nameof(slot), "Control must fit its grid.");
        var cellWidth = grid.Width / columns;
        var cellHeight = grid.Height / rows;
        return new(grid.X + slot % columns * cellWidth + 1, grid.Y + slot / columns * cellHeight + 1,
            Math.Max(1, cellWidth * width - 2), Math.Max(1, cellHeight * height - 2));
    }
}
