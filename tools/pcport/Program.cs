// pcport: makes the PC build's sts2.dll start on iOS under StS2Mono.
//
// The PC build initializes Steam at startup and quits with an error popup when that
// fails, which it always does on iOS, and it starts Sentry crash reporting, whose
// native half isn't in the iOS app. Both are skipped the way the game skips them
// when run from the Godot editor, which is how its developers run it every day:
//   NGame.InitializePlatform()   -> return Task.FromResult(true);
//   SentryService.Initialize()   -> return;
//
// ModelDb also needs Mono's eager static constructors handled, and the game version
// file has to be found (see tools/pcport-fixes, built into StS2Mono.GameFixes.dll):
//   ModelDb.Get<T>(), ModelDb.Get(Type)  start with ModelDbFixes.EnsureLoaded(type)
//   ModelDb.Init(Type[])                 -> ModelDbFixes.Init(injectedModelTypes)
//   ReleaseInfoManager.GetPossibleReleaseInfoPaths() -> ReleaseInfoFixes.GetPossibleReleaseInfoPaths()
//
// Usage: pcport <in sts2.dll> <out sts2.dll> <StS2Mono.GameFixes.dll | --dxgi-only>

using Mono.Cecil;
using Mono.Cecil.Cil;

if (args.Length != 3)
{
    Console.Error.WriteLine("usage: pcport <in sts2.dll> <out sts2.dll> <StS2Mono.GameFixes.dll | --dxgi-only>");
    return 2;
}
string input = Path.GetFullPath(args[0]);
string output = Path.GetFullPath(args[1]);
if (string.Equals(input, output, StringComparison.OrdinalIgnoreCase))
{
    Console.Error.WriteLine("input and output must differ");
    return 2;
}

var resolver = new DefaultAssemblyResolver();
resolver.AddSearchDirectory(Path.GetDirectoryName(input)!);
bool hasPdb = File.Exists(Path.ChangeExtension(input, ".pdb"));
using var module = ModuleDefinition.ReadModule(input, new ReaderParameters
{
    AssemblyResolver = resolver,
    ReadSymbols = hasPdb,
    ReadingMode = ReadingMode.Immediate,
});

DllCompatibility.GuardDxgiProbe(module);
if (args[2] == "--dxgi-only")
{
    WriteResult();
    return 0;
}

using var fixes = ModuleDefinition.ReadModule(Path.GetFullPath(args[2]));

MethodDefinition Find(string type, string name)
{
    TypeDefinition t = module.GetType(type) ?? throw new InvalidOperationException($"{type} not found");
    return t.Methods.SingleOrDefault(m => m.Name == name && m.Parameters.Count == 0)
        ?? throw new InvalidOperationException($"{type}.{name}() not found");
}

void Replace(MethodDefinition method, Action<ILProcessor> emit)
{
    // An async method's body only starts its state machine; the new body doesn't.
    foreach (var attribute in method.CustomAttributes.Where(a => a.AttributeType.Name is "AsyncStateMachineAttribute" or "DebuggerStepThroughAttribute").ToList())
        method.CustomAttributes.Remove(attribute);
    MethodBody body = method.Body;
    body.ExceptionHandlers.Clear();
    body.Variables.Clear();
    body.Instructions.Clear();
    emit(body.GetILProcessor());
    method.DebugInformation.SequencePoints.Clear();
    Console.WriteLine($"  {method.FullName}: replaced");
}

MethodDefinition platform = Find("MegaCrit.Sts2.Core.Nodes.NGame", "InitializePlatform");
if (platform.ReturnType.FullName != "System.Threading.Tasks.Task`1<System.Boolean>")
    throw new InvalidOperationException($"unexpected return type {platform.ReturnType.FullName}");
MethodReference fromResult = FromResultOfBool(module);
Replace(platform, il =>
{
    il.Emit(OpCodes.Ldc_I4_1);
    il.Emit(OpCodes.Call, fromResult);
    il.Emit(OpCodes.Ret);
});

MethodDefinition sentry = Find("MegaCrit.Sts2.Core.Debug.SentryService", "Initialize");
if (sentry.ReturnType.MetadataType != MetadataType.Void)
    throw new InvalidOperationException($"unexpected return type {sentry.ReturnType.FullName}");
Replace(sentry, il => il.Emit(OpCodes.Ret));

TypeDefinition fixesType = fixes.GetType("StS2Mono.GameFixes.ModelDbFixes") ?? throw new InvalidOperationException("ModelDbFixes not found");
MethodReference ensureLoaded = module.ImportReference(fixesType.Methods.Single(m => m.Name == "EnsureLoaded"));
MethodReference fixedInit = module.ImportReference(fixesType.Methods.Single(m => m.Name == "Init"));
MethodReference typeFromHandle = TypeFromHandle(module);
TypeDefinition modelDb = module.GetType("MegaCrit.Sts2.Core.Models.ModelDb") ?? throw new InvalidOperationException("ModelDb not found");

MethodDefinition init = modelDb.Methods.Single(m => m.Name == "Init" && m.Parameters.Count == 1 && m.Parameters[0].ParameterType.FullName == "System.Type[]");
Replace(init, il =>
{
    il.Emit(OpCodes.Ldarg_0);
    il.Emit(OpCodes.Call, fixedInit);
    il.Emit(OpCodes.Ret);
});

MethodDefinition getOfT = modelDb.Methods.Single(m => m.Name == "Get" && m.HasGenericParameters && m.Parameters.Count == 0);
Prepend(getOfT, il => new[]
{
    il.Create(OpCodes.Ldtoken, getOfT.GenericParameters[0]),
    il.Create(OpCodes.Call, typeFromHandle),
    il.Create(OpCodes.Call, ensureLoaded),
    il.Create(OpCodes.Pop),
});
MethodDefinition getByType = modelDb.Methods.Single(m => m.Name == "Get" && !m.HasGenericParameters && m.Parameters.Count == 1 && m.Parameters[0].ParameterType.FullName == "System.Type");
Prepend(getByType, il => new[]
{
    il.Create(OpCodes.Ldarg_0),
    il.Create(OpCodes.Call, ensureLoaded),
    il.Create(OpCodes.Pop),
});

TypeDefinition releaseFixes = fixes.GetType("StS2Mono.GameFixes.ReleaseInfoFixes") ?? throw new InvalidOperationException("ReleaseInfoFixes not found");
MethodReference releasePaths = module.ImportReference(releaseFixes.Methods.Single(m => m.Name == "GetPossibleReleaseInfoPaths"));
MethodDefinition gamePaths = Find("MegaCrit.Sts2.Core.Debug.ReleaseInfoManager", "GetPossibleReleaseInfoPaths");
if (gamePaths.ReturnType.FullName != "System.String[]")
    throw new InvalidOperationException($"unexpected return type {gamePaths.ReturnType.FullName}");
Replace(gamePaths, il =>
{
    il.Emit(OpCodes.Call, releasePaths);
    il.Emit(OpCodes.Ret);
});

MethodReference GameFix(string type, string method) =>
    module.ImportReference(fixes.GetType($"StS2Mono.GameFixes.{type}").Methods.Single(m => m.Name == method));

TypeDefinition mods = module.GetType("MegaCrit.Sts2.Core.Modding.ModManager");
MethodDefinition resolverMethod = mods.Methods.Single(m => m.Name == "HandleAssemblyResolveFailure" && m.Parameters.Count == 2);
Instruction unresolved = resolverMethod.Body.Instructions.Single(i => i.OpCode == OpCodes.Ldnull && i.Next?.OpCode == OpCodes.Ret);
unresolved.OpCode = OpCodes.Ldarg_1;
var resolverIl = resolverMethod.Body.GetILProcessor();
resolverIl.InsertAfter(unresolved, resolverIl.Create(OpCodes.Call, GameFix("ModCompatibility", "ResolveSibling")));

MethodDefinition loadMod = mods.Methods.Single(m => m.Name == "TryLoadMod" && m.Parameters.Count == 1);
Instruction getTypes = loadMod.Body.Instructions.Single(i =>
    i.Operand is MethodReference { Name: "GetTypes" } method && method.DeclaringType.FullName == "System.Reflection.Assembly");
getTypes.OpCode = OpCodes.Call;
getTypes.Operand = GameFix("ModCompatibility", "GetInitializerTypes");
Console.WriteLine("  ModManager: sibling dependency resolution and detailed type-load diagnostics");

TypeDefinition game = module.GetType("MegaCrit.Sts2.Core.Nodes.NGame");
MethodDefinition ready = game.Methods.Single(m => m.Name == "_Ready" && m.Parameters.Count == 0);
MethodDefinition inputEvent = game.Methods.Single(m => m.Name == "_Input" && m.Parameters.Count == 1
    && m.Parameters[0].ParameterType.FullName == "Godot.InputEvent");
Prepend(ready, il => new[]
{
    il.Create(OpCodes.Ldarg_0),
    il.Create(OpCodes.Call, GameFix("TouchInputFixes", "Initialize")),
});
Prepend(inputEvent, il => new[]
{
    il.Create(OpCodes.Ldarg_0),
    il.Create(OpCodes.Ldarg_1),
    il.Create(OpCodes.Call, GameFix("TouchInputFixes", "ObserveTouch")),
});

void Prepend(MethodDefinition method, Func<ILProcessor, Instruction[]> build)
{
    ILProcessor il = method.Body.GetILProcessor();
    Instruction first = method.Body.Instructions[0];
    foreach (Instruction instruction in build(il))
        il.InsertBefore(first, instruction);
    Console.WriteLine($"  {method.FullName}: added entry hook");
}

WriteResult();
return 0;

void WriteResult()
{
    module.Write(output, new WriterParameters { WriteSymbols = hasPdb });
    Console.WriteLine($"written to {output}");
}

// Type.GetTypeFromHandle, as the game's own typeof() expressions reference it.
static MethodReference TypeFromHandle(ModuleDefinition module)
{
    foreach (TypeDefinition type in module.GetTypes())
        foreach (MethodDefinition method in type.Methods.Where(m => m.HasBody))
            foreach (Instruction instruction in method.Body.Instructions)
                if (instruction.Operand is MethodReference { Name: "GetTypeFromHandle" } reference
                    && reference.DeclaringType.FullName == "System.Type")
                    return reference;
    throw new InvalidOperationException("no typeof() in the module to copy Type.GetTypeFromHandle from");
}

// Task.FromResult<bool>, reusing the game's own reference to it when it has one.
static MethodReference FromResultOfBool(ModuleDefinition module)
{
    foreach (TypeDefinition type in module.GetTypes())
        foreach (MethodDefinition method in type.Methods.Where(m => m.HasBody))
            foreach (Instruction instruction in method.Body.Instructions)
                if (instruction.Operand is GenericInstanceMethod { Name: "FromResult" } generic
                    && generic.DeclaringType.FullName == "System.Threading.Tasks.Task"
                    && generic.GenericArguments.Count == 1
                    && generic.GenericArguments[0].MetadataType == MetadataType.Boolean)
                    return generic;

    TypeReference task = new TypeReference("System.Threading.Tasks", "Task", module, module.TypeSystem.CoreLibrary);
    TypeReference taskOfT = new TypeReference("System.Threading.Tasks", "Task`1", module, module.TypeSystem.CoreLibrary);
    taskOfT.GenericParameters.Add(new GenericParameter("TResult", taskOfT));
    var open = new MethodReference("FromResult", module.TypeSystem.Void, task);
    var result = new GenericParameter("TResult", open);
    open.GenericParameters.Add(result);
    var returns = new GenericInstanceType(taskOfT);
    returns.GenericArguments.Add(result);
    open.ReturnType = returns;
    open.Parameters.Add(new ParameterDefinition(result));
    var closed = new GenericInstanceMethod(open);
    closed.GenericArguments.Add(module.TypeSystem.Boolean);
    return closed;
}
