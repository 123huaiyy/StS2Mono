namespace StS2Mono.HarmonyTest.Missing
{
#if !WITHOUT_TYPES
    // A library type that the installed version of the library lacks, like BaseLib types
    // that mods built against a newer BaseLib use.
    public class MissingBase
    {
    }

    // Like ICombatState, which mods built for newer game versions use in method signatures.
    public class MissingParam
    {
    }
#endif

    public static class Library
    {
        public const string Name = "stand-in library";
    }

    // Like the game's AncientDialogueSet, whose setters became `init` in later versions:
    // mods built against those call `void modreq(IsExternalInit) set_Value(int)`, and the
    // installed version only has the plain setter.
    public class InitProps
    {
#if WITHOUT_TYPES
        public int Value { get; set; }
#else
        public int Value { get; init; }
#endif
    }

    public enum Size
    {
        Small,
        Big,
    }

    public class Entry
    {
        public virtual string Name => "entry";
    }

    public class DerivedEntry : Entry
    {
        public override string Name => "derived";
    }

    // Signatures that changed between versions, as the game's do (MegaAnimationState's
    // AddEmptyAnimation stopped returning its track entry). The test's mod is built
    // against the first version and runs against the WITHOUT_TYPES one; StS2Mono's
    // interpreter adapts its calls (mono/patch-mono.ps1, transform.c, drift).
    public class Drifted
    {
        public static string Last = "";
        public int Count;

#if WITHOUT_TYPES
        public Drifted(int count, bool negate = false) { Count = negate ? -count : count; }
        public void AddEmpty(int track) { Last = "added " + track; }
        public string Describe(int a, bool loud = true, string suffix = "!", float scale = 1.5f, Size size = Size.Big, object? extra = null, long big = 1L << 40)
            => $"{a} {loud} {suffix} {scale} {size} {extra == null} {big}";
        public int Clear() { Last = "cleared"; return 3; }
        public void Measure() { Last = "measured"; }
        public DerivedEntry Make() => new DerivedEntry();
        public static string Take(Entry entry) => entry.Name;
        public static string Pick(Size size) => size.ToString();
#else
        public Drifted(int count) { Count = count; }
        public Entry AddEmpty(int track) { Last = "added " + track; return new Entry(); }
        public string Describe(int a) => a.ToString();
        public void Clear() { Last = "cleared"; }
        public int Measure() { Last = "measured"; return 9; }
        public Entry Make() => new Entry();
        public static string Take(DerivedEntry entry) => entry.Name;
        public static string Pick(int size) => size.ToString();
#endif
    }
}
