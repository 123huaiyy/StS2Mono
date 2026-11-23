using Godot;
using MegaCrit.Sts2.Core.Nodes;
using MegaCrit.Sts2.Core.Nodes.Combat;

namespace StS2Mono.GameFixes;

public static class TouchInputFixes
{
    private static readonly HashSet<int> ActiveTouches = new();

    public static void Initialize(NGame game)
    {
        if (!OperatingSystem.IsIOS())
            return;

        // Keep Godot's viewport coordinates and regular mouse/controller handling.
        Input.EmulateMouseFromTouch = true;
        Input.UseAccumulatedInput = false;
        game.GetTree().Root.FocusExited += ActiveTouches.Clear;
    }

    public static void ObserveTouch(NGame game, InputEvent input)
    {
        if (!OperatingSystem.IsIOS() || input is not InputEventScreenTouch touch)
            return;

        if (!touch.Pressed || touch.Canceled)
        {
            ActiveTouches.Remove(touch.Index);
            return;
        }

        if (ActiveTouches.Add(touch.Index) && ActiveTouches.Count == 2
            && NPlayerHand.Instance is { InCardPlay: true } hand
            && GodotObject.IsInstanceValid(hand))
        {
            hand.CancelAllCardPlay();
            game.GetViewport().SetInputAsHandled();
        }
    }
}
