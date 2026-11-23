using Godot;

namespace StS2Mono.GameFixes;

// The PC build reads release_info.json, which holds the game version that the mod loader
// and mods such as RitsuLib check, only from next to the executable. On iOS that's the
// app bundle, which installing the app doesn't put the file in; the iOS pack carries it
// instead. tools/pcport makes ReleaseInfoManager.GetPossibleReleaseInfoPaths call this,
// which copies the packed file next to the executable when it's missing or differs, so
// mods that read it from there find it too, and also offers a copy in the user folder
// in case the bundle can't be written.
public static class ReleaseInfoFixes
{
    const string Name = "release_info.json";

    public static string[] GetPossibleReleaseInfoPaths()
    {
        string bundled = Path.Combine(Path.GetDirectoryName(OS.GetExecutablePath()) ?? string.Empty, Name);
        string user = ProjectSettings.GlobalizePath("user://" + Name);
        string? packed = null;
        try
        {
            if (Godot.FileAccess.FileExists("res://" + Name))
                packed = Godot.FileAccess.GetFileAsString("res://" + Name);
        }
        catch (Exception e)
        {
            GD.PrintErr($"[StS2Mono] reading res://{Name} failed: {e.Message}");
        }
        if (!string.IsNullOrEmpty(packed))
        {
            CopyIfDifferent(packed, bundled);
            CopyIfDifferent(packed, user);
        }
        return new[] { bundled, user };
    }

    static void CopyIfDifferent(string text, string path)
    {
        try
        {
            if (!File.Exists(path) || File.ReadAllText(path) != text)
                File.WriteAllText(path, text);
        }
        catch (Exception e)
        {
            GD.PrintErr($"[StS2Mono] writing {path} failed: {e.Message}");
        }
    }
}
