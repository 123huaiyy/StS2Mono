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
}
