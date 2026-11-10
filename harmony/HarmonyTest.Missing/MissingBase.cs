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
}
