using Mono.Cecil;
using Mono.Cecil.Cil;

internal static class DllCompatibility
{
    internal static void GuardDxgiProbe(ModuleDefinition module)
    {
        const string dxgiType = "Vortice.DXGI.DXGI";
        var method = module.GetType("MegaCrit.Sts2.Core.Debug.OsDebugInfo").Methods
            .Single(m => m.Name == "GetSystemInfoString" && m.IsStatic && !m.HasParameters
                && m.ReturnType.MetadataType == MetadataType.String);
        var instructions = method.Body.Instructions;
        var factory = instructions.Single(i => i.OpCode == OpCodes.Call &&
            i.Operand is GenericInstanceMethod m && m.DeclaringType.FullName == dxgiType
            && m.Name == "CreateDXGIFactory1"
            && m.GenericArguments.Single().FullName == "Vortice.DXGI.IDXGIFactory1");
        var loadLocal = factory.Previous;
        var result = factory.Next;
        var equals = result.Next;
        var branch = equals.Next;
        if (loadLocal.OpCode != OpCodes.Ldloca_S || loadLocal.Operand is not VariableDefinition local
            || local.VariableType.FullName != "Vortice.DXGI.IDXGIFactory1"
            || result.OpCode != OpCodes.Ldsfld || result.Operand is not FieldReference resultField
            || resultField.FullName != "SharpGen.Runtime.Result SharpGen.Runtime.Result::Ok"
            || equals.OpCode != OpCodes.Call || equals.Operand is not MethodReference equality
            || equality.Name != "op_Equality" || equality.DeclaringType.FullName != "SharpGen.Runtime.Result"
            || branch.OpCode != OpCodes.Brfalse || branch.Operand is not Instruction afterDxgi)
            throw new InvalidDataException("Unexpected DXGI instruction sequence.");

        var runtime = module.AssemblyReferences.Single(r => r.Name == "System.Runtime");
        var operatingSystem = new TypeReference("System", "OperatingSystem", module, runtime);
        var isWindows = new MethodReference("IsWindows", module.TypeSystem.Boolean, operatingSystem);
        if (loadLocal.Previous.OpCode == OpCodes.Brfalse && ReferenceEquals(loadLocal.Previous.Operand, afterDxgi)
            && loadLocal.Previous.Previous.Operand is MethodReference guard && guard.FullName == isWindows.FullName)
            return;

        // Godot has already reported the rendering device above this optional DirectX probe.
        var il = method.Body.GetILProcessor();
        il.InsertBefore(loadLocal, il.Create(OpCodes.Call, isWindows));
        il.InsertBefore(loadLocal, il.Create(OpCodes.Brfalse, afterDxgi));
        Console.WriteLine($"  {method.FullName}: DXGI probe restricted to Windows");
    }
}
