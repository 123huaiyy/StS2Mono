namespace StS2Mono.HarmonyTest.Missing
{
#if !WITHOUT_TYPES
    // A library type that the installed version of the library lacks, like BaseLib types
    // that mods built against a newer BaseLib use.
    public class MissingBase
    {
    }
#endif

    public static class Library
    {
        public const string Name = "stand-in library";
    }
}
