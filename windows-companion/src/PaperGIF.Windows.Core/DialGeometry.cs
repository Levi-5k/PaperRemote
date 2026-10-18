namespace PaperGIF.Windows.Core;

public static class DialGeometry
{
    /// <summary>
    /// Signed travel from <paramref name="start"/> to a dragged end-stop angle; positive is clockwise.
    /// The side follows the drag continuously, so dragging the end stop past the start flips the dial
    /// to counterclockwise, and crossing the far side pins it at a full turn.
    /// </summary>
    public static double SignedTravel(double dragAngle, double start, double previous)
    {
        var clockwise = (dragAngle - start) % 360;
        if (clockwise < 0) clockwise += 360;
        var counterclockwise = clockwise - 360;
        var nearest = Math.Abs(clockwise - previous) <= Math.Abs(counterclockwise - previous)
            ? clockwise : counterclockwise;
        if (Math.Abs(nearest - previous) > 180) return previous < 0 ? -360 : 360;
        if (Math.Abs(nearest) < 1) return nearest < 0 || (nearest == 0 && previous < 0) ? -1 : 1;
        return nearest;
    }
}
