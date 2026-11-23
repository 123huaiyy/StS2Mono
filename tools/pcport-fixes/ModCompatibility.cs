using System.Reflection;
using System.Runtime.Loader;
using MegaCrit.Sts2.Core.Logging;

namespace StS2Mono.GameFixes;

public static class ModCompatibility
{
    public static Assembly? ResolveSibling(ResolveEventArgs args)
    {
        Assembly? requester = args.RequestingAssembly;
        if (!OperatingSystem.IsIOS() || requester == null || requester.IsDynamic)
            return null;

        string? directory = Path.GetDirectoryName(requester.Location);
        if (directory == null || !IsModDirectory(directory))
            return null;

        var reference = new AssemblyName(args.Name);
        string? name = reference.Name;
        if (string.IsNullOrWhiteSpace(name) || name != Path.GetFileName(name) || name.Contains('\\'))
            return null;

        string path = Path.Combine(directory, name + ".dll");
        if (!File.Exists(path))
            return null;

        try
        {
            AssemblyName candidate = AssemblyName.GetAssemblyName(path);
            if (!MatchesReference(reference, candidate))
            {
                Log.Warn($"[StS2Mono] {requester.GetName().Name}: {path} is {candidate.FullName}, requested {reference.FullName}");
                return null;
            }

            var context = AssemblyLoadContext.GetLoadContext(requester);
            Assembly? resolved = context?.LoadFromAssemblyPath(path);
            if (resolved != null)
                Log.Info($"[StS2Mono] {requester.GetName().Name}: loaded dependency {resolved.FullName} from {path}");
            return resolved;
        }
        catch (Exception error) when (error is IOException or BadImageFormatException or UnauthorizedAccessException)
        {
            Log.Warn($"[StS2Mono] {requester.GetName().Name}: could not load dependency {path}: {error.GetType().Name}: {error.Message}");
            return null;
        }
    }

    public static Type[] GetInitializerTypes(Assembly assembly)
    {
        try
        {
            return assembly.GetTypes();
        }
        catch (ReflectionTypeLoadException error)
        {
            foreach (var failure in error.LoaderExceptions.OfType<Exception>())
                Log.Error($"[StS2Mono] {assembly.GetName().Name}: {failure.GetType().Name}: {failure.Message}");
            throw;
        }
    }

    private static bool IsModDirectory(string path)
    {
        for (DirectoryInfo? entry = new DirectoryInfo(path); entry != null; entry = entry.Parent)
        {
            if (entry.Name.Equals("mods", StringComparison.Ordinal))
                return true;
        }
        return false;
    }

    private static bool MatchesReference(AssemblyName requested, AssemblyName candidate)
    {
        byte[] requestedToken = requested.GetPublicKeyToken() ?? Array.Empty<byte>();
        byte[] candidateToken = candidate.GetPublicKeyToken() ?? Array.Empty<byte>();
        return string.Equals(requested.Name, candidate.Name, StringComparison.OrdinalIgnoreCase)
            && string.Equals(requested.CultureName ?? "", candidate.CultureName ?? "", StringComparison.OrdinalIgnoreCase)
            && requestedToken.AsSpan().SequenceEqual(candidateToken)
            && (requested.Version == null || candidate.Version >= requested.Version);
    }
}
