using System.Drawing;
using System.Reflection;
using System.Windows.Forms;
using PaperGIF.Windows.Core.Models;
using Xunit;

namespace PaperGIF.Windows.Host.Tests;

public sealed class RemotePreviewInteractionTests
{
    [Fact]
    public async Task ButtonColorPropertiesUseNativeSwatchEditors()
    {
        await OnSTA(() =>
        {
            using var grid = new PropertyGrid();
            var properties = System.ComponentModel.TypeDescriptor.GetProperties(typeof(ControlProperties));
            foreach (var name in new[] { nameof(ControlProperties.ForegroundColor), nameof(ControlProperties.BackgroundColor), nameof(ControlProperties.ImageColor) })
            {
                var editor = Assert.IsAssignableFrom<System.Drawing.Design.UITypeEditor>(
                    properties[name]!.GetEditor(typeof(System.Drawing.Design.UITypeEditor)));
                Assert.True(editor.GetPaintValueSupported());
                Assert.Equal(System.Drawing.Design.UITypeEditorEditStyle.DropDown, editor.GetEditStyle());
            }
        });
    }

    [Fact]
    public async Task ButtonImagePreservesRGBAndCanBeTintedOrFaded()
    {
        await OnSTA(() =>
        {
            using var source = new Bitmap(8, 8);
            using (var graphics = Graphics.FromImage(source)) graphics.Clear(Color.Red);
            var bytes = ButtonImageStore.Encode(source);
            Assert.Equal(2, bytes[4]);
            Assert.Equal(10 + 8 * 8 * 2, bytes.Length);
            var texture = new RemoteButtonTexture { Kind = RemoteButtonTextureKind.Image, PreserveColor = true, Fade = 0 };
            using var original = ButtonImageStore.Render(bytes, texture, 20, 20, Color.White, Color.Blue, null);
            Assert.Equal(Color.Red.ToArgb(), original!.GetPixel(10, 10).ToArgb());
            using var tinted = ButtonImageStore.Render(bytes, texture, 20, 20, Color.White, Color.Blue, "00FF00");
            var tint = tinted!.GetPixel(10, 10);
            Assert.True(tint.G > tint.R && tint.G > tint.B);
            texture.Fade = 50;
            using var faded = ButtonImageStore.Render(bytes, texture, 20, 20, Color.White, Color.Blue, null);
            Assert.Equal(Color.FromArgb(255, 128, 128).ToArgb(), faded!.GetPixel(10, 10).ToArgb());
            Assert.Null(ButtonImageStore.Render(bytes[..^1], texture, 20, 20, Color.White, Color.Blue, null));
            texture.Pattern = RemoteButtonPattern.Rings;
            texture.Fade = 0;
            using var pattern = ButtonImageStore.RenderPattern(texture, 20, 20, Color.Red, Color.Blue, "00FF00");
            Assert.Equal(Color.Lime.ToArgb(), pattern.GetPixel(10, 10).ToArgb());
        });
    }

    [Fact]
    public async Task ControlPreviewUsesBackgroundAndTextColors()
    {
        await OnSTA(() =>
        {
            var descriptor = AMOLED();
            var control = new RemoteControl { Title = "Colors", TintHex = "FF0000", BackgroundTintHex = "0000FF", GridWidth = 2, GridHeight = 2, LayoutSlot = 0 };
            using var preview = new RemotePreviewPanel
            {
                Size = new Size(400, 600), Descriptor = descriptor, BoardLayout = descriptor.Layout,
                Page = new RemotePage { GridColumns = 2, GridRows = 2, Controls = [control] },
            };
            using var bitmap = new Bitmap(preview.Width, preview.Height);
            preview.DrawToBitmap(bitmap, preview.ClientRectangle);
            var frame = Frames<Guid>(preview, "controlFrames")[control.Id];
            var blue = 0;
            var red = 0;
            for (var row = frame.Top + 10; row < frame.Bottom - 10; row++)
            for (var column = frame.Left + 10; column < frame.Right - 10; column++)
            {
                var pixel = bitmap.GetPixel(column, row);
                if (pixel.B > 200 && pixel.R < 30 && pixel.G < 30) blue++;
                if (pixel.R > 200 && pixel.B < 30 && pixel.G < 30) red++;
            }
            Assert.True(blue > 500 && red > 20, $"Background blue={blue}, text red={red}");
        });
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task OverlappingAMOLEDInputOnlyWinsInHardwareMode(bool hardwareMode)
    {
        await OnSTA(() =>
        {
            var descriptor = AMOLED();
            var control = new RemoteControl { Title = "Test control", GridWidth = 2, GridHeight = 2, LayoutSlot = 0 };
            using var preview = new RemotePreviewPanel
            {
                Size = new Size(400, 600), Descriptor = descriptor, BoardLayout = descriptor.Layout,
                EditHardwareInputs = hardwareMode,
                Page = new RemotePage { GridColumns = 2, GridRows = 2, Controls = [control] },
            };
            Guid? selectedControl = null;
            string? selectedInput = null;
            preview.ControlSelected += (_, id) => selectedControl = id;
            preview.InputSelected += (_, id) => selectedInput = id;
            using var bitmap = new Bitmap(preview.Width, preview.Height);
            preview.DrawToBitmap(bitmap, preview.ClientRectangle);
            var frame = Frames<Guid>(preview, "controlFrames")[control.Id];
            var location = new Point(frame.Left + frame.Width / 2, frame.Top + frame.Height / 2);
            Assert.True(Frames<string>(preview, "inputFrames")["dial-1"].Contains(location));
            Click(preview, location);
            Assert.Equal(hardwareMode ? null : (Guid?)control.Id, selectedControl);
            Assert.Equal(hardwareMode ? "dial-1" : null, selectedInput);
        });
    }

    [Fact]
    public async Task ScreenlessInputsRemainSelectableWithoutHardwareMode()
    {
        await OnSTA(() =>
        {
            var descriptor = AMOLED();
            descriptor = descriptor with
            {
                Display = null, Layout = descriptor.Layout with { Screen = null },
                Capabilities = descriptor.Capabilities with { Media = false },
            };
            using var preview = new RemotePreviewPanel
            {
                Size = new Size(400, 600), Descriptor = descriptor, BoardLayout = descriptor.Layout,
            };
            string? selectedInput = null;
            preview.InputSelected += (_, id) => selectedInput = id;
            using var bitmap = new Bitmap(preview.Width, preview.Height);
            preview.DrawToBitmap(bitmap, preview.ClientRectangle);
            var frame = Frames<string>(preview, "inputFrames")["dial-1"];
            Click(preview, new Point(frame.Left + frame.Width / 2, frame.Top + frame.Height / 2));
            Assert.Equal("dial-1", selectedInput);
        });
    }

    [Theory]
    [InlineData(320)]
    [InlineData(420)]
    public async Task AllInspectorTabsFitNarrowInspector(int width)
    {
        await OnSTA(() =>
        {
            using var tabs = new ModernTabControl { Size = new Size(width, 600) };
            foreach (var title in new[] { "Add Controls", "Control", "Modules", "Connections", "Hardware", "Device" })
                tabs.TabPages.Add(new TabPage(title));
            tabs.CreateControl();
            Assert.True(tabs.Multiline);
            for (var selected = 0; selected < tabs.TabCount; ++selected)
            {
                tabs.SelectedIndex = selected;
                for (var index = 0; index < tabs.TabCount; ++index)
                    Assert.True(tabs.ClientRectangle.Contains(tabs.GetTabRect(index)),
                        $"Tab {tabs.TabPages[index].Text} is clipped at width {width}.");
            }
        });
    }

    private static DeviceDescriptor AMOLED() => DeviceDescriptor.Legacy("preview") with
    {
        BoardID = "paperremote.waveshare-amoled-18-v2",
        Display = new(368, 448, true, "rgb565", 0),
        Inputs = [new("dial-1", "Dial", "dial", ["change"], 0, 100)],
        Layout = new(368, 448, new(0, 0, 368, 448), [new("dial-1", 64, 36, 240, 240)]),
    };

    private static Dictionary<TKey, Rectangle> Frames<TKey>(RemotePreviewPanel preview, string field) where TKey : notnull =>
        (Dictionary<TKey, Rectangle>)typeof(RemotePreviewPanel).GetField(field, BindingFlags.Instance | BindingFlags.NonPublic)!
            .GetValue(preview)!;

    private static void Click(RemotePreviewPanel preview, Point location) =>
        typeof(RemotePreviewPanel).GetMethod("OnMouseClick", BindingFlags.Instance | BindingFlags.NonPublic)!
            .Invoke(preview, [new MouseEventArgs(MouseButtons.Left, 1, location.X, location.Y, 0)]);

    private static Task OnSTA(Action check)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try { check(); completion.TrySetResult(); }
            catch (Exception exception) { completion.TrySetException(exception); }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.IsBackground = true;
        thread.Start();
        return completion.Task.WaitAsync(TimeSpan.FromSeconds(10));
    }
}