/ Points Harmony at StS2Mono's interpreter redirect instead of MonoMod.Core,
// whose native detours need writable machine code that iOS doesn't allow.
//
// In Harmony 2.4.2 only two methods reach MonoMod.Core (`scan` lists them):
//   PatchTools.DetourMethod   applies a patch      -> StS2Mono.InterpDetour.Detour
//   AccessTools.Identifiable  normalizes a method  -> StS2Mono.InterpDetour.Identifiable
//
// Usage:
//   harmonypatch patch <0Harmony.dll> <StS2Mono.Harmony.dll> <output.dll>
//   harmonypatch scan <0Harmony.dll>          methods outside MonoMod.Core that use it
//   harmonypatch il <assembly> <Type::Method>  prints a method's IL

using Mono.Cecil;
using Mono.Cecil.Cil;

if (args.Length == 4 && args[0] == "patch")
{
    return Patch(args[1], args[2], args[3]);
}
if (args.Length == 2 && args[0] == "scan")
{
    return Scan(args[1]);
}
if (args.Length == 3 && args[0] == "il")
{
    return PrintIL(args[1], args[2]);
}
Console.Error.WriteLine("usage: harmonypatch patch <0Harmony.dll> <StS2Mono.Harmony.dll> <output.dll>");
Console.Error.WriteLine("       harmonypatch scan <0Harmony.dll>");
Console.Error.WriteLine("       harmonypatch il <assembly> <Type::Method>");
return 2;

static int Patch(string harmonyPath, string adapterPath, string outputPath)
{
    if (string.Equals(Path.GetFullPath(harmonyPath), Path.GetFullPath(outputPath), StringComparison.OrdinalIgnoreCase))
    {
        Console.Error.WriteLine("input and output must differ");
        return 2;
    }

    var resolver = new DefaultAssemblyResolver();
    resolver.AddSearchDirectory(Path.GetDirectoryName(Path.GetFullPath(harmonyPath))!);
    resolver.AddSearchDirectory(Path.GetDirectoryName(Path.GetFullPath(adapterPath))!);
    var readerParameters = new ReaderParameters { AssemblyResolver = resolver };

    using var harmony = AssemblyDefinition.ReadAssembly(harmonyPath, readerParameters);
    using var adapter = AssemblyDefinition.ReadAssembly(adapterPath, readerParameters);
    ModuleDefinition module = harmony.MainModule;
    TypeDefinition interpDetour = adapter.MainModule.GetType("StS2Mono.InterpDetour")
        ?? throw new InvalidOperationException("StS2Mono.InterpDetour not found in the adapter");

    Forward(module, "HarmonyLib.PatchTools", "DetourMethod", interpDetour, "Detour");
    Forward(module, "HarmonyLib.AccessTools", "Identifiable", interpDetour, "Identifiable");

    harmony.Write(outputPath);
    Console.WriteLine($"written to {outputPath}");
    return 0;
}

// Replaces the body of the static method typeName::methodName with a call to the
// adapter method of the same signature.
static void Forward(ModuleDefinition module, string typeName, string methodName, TypeDefinition adapterType, string adapterMethodName)
{
    TypeDefinition type = module.GetType(typeName) ?? throw new InvalidOperationException($"{typeName} not found");
    MethodDefinition method = Single(type.Methods.Where(m => m.Name == methodName), $"{typeName}::{methodName}");
    MethodDefinition target = Single(adapterType.Methods.Where(m => m.Name == adapterMethodName), $"{adapterType.FullName}::{adapterMethodName}");

    if (!method.IsStatic || !target.IsStatic
        || method.ReturnType.FullName != target.ReturnType.FullName
        || !method.Parameters.Select(p => p.ParameterType.FullName).SequenceEqual(target.Parameters.Select(p => p.ParameterType.FullName)))
    {
        throw new InvalidOperationException($"signatures differ: {method.FullName} vs {target.FullName}");
    }

    MethodBody body = method.Body;
    body.Instructions.Clear();
    body.ExceptionHandlers.Clear();
    body.Variables.Clear();
    body.InitLocals = false;
    ILProcessor il = body.GetILProcessor();
    for (int i = 0; i < method.Parameters.Count; i++)
    {
        il.Emit(OpCodes.Ldarg, method.Parameters[i]);
    }
    il.Emit(OpCodes.Call, module.ImportReference(target));
    il.Emit(OpCodes.Ret);
    Console.WriteLine($"  {method.FullName} -> {target.DeclaringType.FullName}::{target.Name}");
}

static T Single<T>(IEnumerable<T> items, string what)
{
    var list = items.ToList();
    if (list.Count != 1)
    {
        throw new InvalidOperationException($"expected one {what}, found {list.Count}");
    }
    return list[0];
}

static int Scan(string path)
{
    using var assembly = AssemblyDefinition.ReadAssembly(path);
    foreach (TypeDefinition type in AllTypes(assembly.MainModule.Types))
    {
        // MonoMod.Core is merged into 0Harmony; only its callers are of interest.
        if (OutermostType(type).Namespace.StartsWith("MonoMod.Core", StringComparison.Ordinal))
        {
            continue;
        }
        foreach (MethodDefinition method in type.Methods.Where(m => m.HasBody))
        {
            var uses = method.Body.Instructions
                .Select(i => i.Operand as MemberReference)
                .Where(m => m != null && m.FullName.Contains("MonoMod.Core", StringComparison.Ordinal))
                .Select(m => m!.FullName)
                .Distinct()
                .ToList();
            if (uses.Count > 0)
            {
                Console.WriteLine($"{type.FullName}::{method.Name}");
                uses.ForEach(use => Console.WriteLine($"    {use}"));
            }
        }
    }
    return 0;
}

static int PrintIL(string path, string name)
{
    using var assembly = AssemblyDefinition.ReadAssembly(path);
    foreach (TypeDefinition type in AllTypes(assembly.MainModule.Types))
    {
        foreach (MethodDefinition method in type.Methods.Where(m => m.HasBody && $"{type.FullName}::{m.Name}" == name))
        {
            Console.WriteLine(method.FullName);
            foreach (Instruction instruction in method.Body.Instructions)
            {
                Console.WriteLine($"    {instruction}");
            }
        }
    }
    return 0;
}

static TypeDefinition OutermostType(TypeDefinition type) => type.DeclaringType is null ? type : OutermostType(type.DeclaringType);

static IEnumerable<TypeDefinition> AllTypes(IEnumerable<TypeDefinition> types)
{
    foreach (TypeDefinition type in types)
    {
        yield return type;
        foreach (TypeDefinition nested in AllTypes(type.NestedTypes))
        {
            yield return nested;
        }
    }
}
