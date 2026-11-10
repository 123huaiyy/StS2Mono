// Points Harmony at StS2Mono's interpreter redirect instead of MonoMod.Core,
// whose native detours need writable machine code that iOS doesn't allow.
//
// In Harmony 2.4.2 only two methods reach MonoMod.Core (`scan` lists them):
//   PatchTools.DetourMethod   applies a patch      -> StS2Mono.InterpDetour.Detour
//   AccessTools.Identifiable  normalizes a method  -> StS2Mono.InterpDetour.Identifiable
// Also, for mods built for newer game versions, which often target a few methods or IL
// sequences this one lacks:
//   Harmony.PatchAll skips a patch class that fails       -> InterpDetour.SkipFailedPatchClass
//   PatchProcessor.Patch (Harmony.Patch) returns null      -> InterpDetour.SkipFailedPatch
//   AccessTools.GetTypesFromAssembly survives Mono's TypeLoadException -> InterpDetour.GetTypesFromAssembly
//
// Usage:
//   harmonypatch patch <0Harmony.dll> <StS2Mono.Harmony.dll> <output.dll>
//   harmonypatch scan <0Harmony.dll>          methods outside MonoMod.Core that use it
//   harmonypatch il <assembly> <Type::Method>  prints a method's IL

using Mono.Cecil;
using Mono.Cecil.Cil;
using Mono.Cecil.Rocks;

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
    Forward(module, "HarmonyLib.AccessTools", "GetTypesFromAssembly", interpDetour, "GetTypesFromAssembly");
    CatchPatchClassFailures(module, interpDetour);
    CatchPatchFailures(module, interpDetour);

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

// Harmony.PatchAll(Assembly) runs `type => CreateClassProcessor(type).Patch()` for
// every patch class and stops at the first one that throws. Wraps that lambda's
// body in a catch that reports the failure to the adapter and moves on:
//   try { CreateClassProcessor(type).Patch(); } catch (Exception e) { InterpDetour.SkipFailedPatchClass(e, type); }
static void CatchPatchClassFailures(ModuleDefinition module, TypeDefinition adapterType)
{
    TypeDefinition harmonyType = module.GetType("HarmonyLib.Harmony") ?? throw new InvalidOperationException("HarmonyLib.Harmony not found");
    MethodDefinition action = Single(harmonyType.Methods.Where(m =>
        m.Name.StartsWith("<PatchAll>", StringComparison.Ordinal) && !m.IsStatic && m.HasBody
        && m.ReturnType.FullName == "System.Void" && m.Parameters.Count == 1 && m.Parameters[0].ParameterType.FullName == "System.Type"
        && m.Body.Instructions.Any(i => i.Operand is MethodReference r && r.Name == "CreateClassProcessor")),
        "PatchAll lambda that patches one class");
    MethodReference createClassProcessor = (MethodReference)action.Body.Instructions.Single(i => i.Operand is MethodReference r && r.Name == "CreateClassProcessor").Operand;
    MethodReference patch = (MethodReference)action.Body.Instructions.Single(i => i.Operand is MethodReference r && r.Name == "Patch").Operand;
    MethodDefinition report = Single(adapterType.Methods.Where(m => m.Name == "SkipFailedPatchClass"), $"{adapterType.FullName}::SkipFailedPatchClass");

    MethodBody body = action.Body;
    body.Instructions.Clear();
    body.ExceptionHandlers.Clear();
    ILProcessor il = body.GetILProcessor();
    Instruction ret = il.Create(OpCodes.Ret);
    Instruction tryStart = il.Create(OpCodes.Ldarg_0);
    Instruction handlerStart = il.Create(OpCodes.Ldarg_1);
    il.Append(tryStart);
    il.Append(il.Create(OpCodes.Ldarg_1));
    il.Append(il.Create(OpCodes.Call, createClassProcessor));
    il.Append(il.Create(OpCodes.Callvirt, patch));
    il.Append(il.Create(OpCodes.Pop));
    il.Append(il.Create(OpCodes.Leave, ret));
    il.Append(handlerStart); // the exception is on the stack, then the type
    il.Append(il.Create(OpCodes.Call, module.ImportReference(report)));
    il.Append(il.Create(OpCodes.Leave, ret));
    il.Append(ret);
    body.ExceptionHandlers.Add(new ExceptionHandler(ExceptionHandlerType.Catch)
    {
        TryStart = tryStart,
        TryEnd = handlerStart,
        HandlerStart = handlerStart,
        HandlerEnd = ret,
        CatchType = module.ImportReference(report.Parameters[0].ParameterType),
    });
    Console.WriteLine($"  {action.FullName}: failures go to {adapterType.FullName}::{report.Name}");
}

// PatchProcessor.Patch(), which Harmony.Patch runs, throws when a patch can't be
// applied, ending whatever the caller was doing. Wraps its whole body:
//   try { <body> } catch (Exception e) { InterpDetour.SkipFailedPatch(e, this.original); return null; }
// A failed patch never reaches Harmony's shared state (that's saved after the replacement
// is made), so later patches of the same method aren't affected.
static void CatchPatchFailures(ModuleDefinition module, TypeDefinition adapterType)
{
    TypeDefinition processorType = module.GetType("HarmonyLib.PatchProcessor") ?? throw new InvalidOperationException("HarmonyLib.PatchProcessor not found");
    MethodDefinition patch = Single(processorType.Methods.Where(m => m.Name == "Patch" && !m.IsStatic && m.Parameters.Count == 0), "PatchProcessor.Patch()");
    FieldDefinition original = Single(processorType.Fields.Where(f => f.Name == "original"), "PatchProcessor.original");
    MethodDefinition report = Single(adapterType.Methods.Where(m => m.Name == "SkipFailedPatch"), $"{adapterType.FullName}::SkipFailedPatch");

    MethodBody body = patch.Body;
    body.SimplifyMacros(); // instructions get inserted; short branches may no longer reach
    ILProcessor il = body.GetILProcessor();
    var result = new VariableDefinition(patch.ReturnType);
    body.Variables.Add(result);
    Instruction end = il.Create(OpCodes.Ldloc, result);

    // Each `ret` becomes `stloc result; leave end`, changed in place so branches to it still land.
    foreach (Instruction ret in body.Instructions.Where(i => i.OpCode == OpCodes.Ret).ToList())
    {
        ret.OpCode = OpCodes.Stloc;
        ret.Operand = result;
        il.InsertAfter(ret, il.Create(OpCodes.Leave, end));
    }
    Instruction tryStart = body.Instructions[0];
    Instruction handlerStart = il.Create(OpCodes.Ldarg_0);
    il.Append(handlerStart); // the exception is on the stack, then this.original
    il.Append(il.Create(OpCodes.Ldfld, original));
    il.Append(il.Create(OpCodes.Call, module.ImportReference(report)));
    il.Append(il.Create(OpCodes.Ldnull));
    il.Append(il.Create(OpCodes.Stloc, result));
    il.Append(il.Create(OpCodes.Leave, end));
    il.Append(end);
    il.Append(il.Create(OpCodes.Ret));
    // Added last: an enclosing handler has to come after the ones it contains.
    body.ExceptionHandlers.Add(new ExceptionHandler(ExceptionHandlerType.Catch)
    {
        TryStart = tryStart,
        TryEnd = handlerStart,
        HandlerStart = handlerStart,
        HandlerEnd = end,
        CatchType = module.ImportReference(report.Parameters[0].ParameterType),
    });
    body.OptimizeMacros();
    Console.WriteLine($"  {patch.FullName}: failures go to {adapterType.FullName}::{report.Name}");
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
