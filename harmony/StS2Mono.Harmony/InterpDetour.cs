// Applies Harmony patches through Mono's interpreter.
//
// Harmony normally makes a patched method jump to the replacement it generates
// by rewriting the method's machine code (MonoMod.Core detours). On iOS the game's
// C# runs in Mono's interpreter and there's no machine code to rewrite. StS2Mono's
// build of Mono can instead redirect calls of one interpreted method to another
// (mono_interp_redirect_method, added by mono/patch-mono.ps1), and harmonypatch
// rewrites 0Harmony.dll so that HarmonyLib.PatchTools.DetourMethod comes here.

using System;
using System.Collections.Generic;
using System.Reflection;
using System.Reflection.Emit;
using System.Runtime.InteropServices;

namespace StS2Mono
{
    public static class InterpDetour
    {
        // On iOS the bridge answers this P/Invoke itself, since Mono is linked into
        // it. Desktop Mono is libcoreclr, which exports the function.
        [DllImport("libcoreclr", EntryPoint = "mono_interp_redirect_method")]
        private static extern int RedirectMethod(IntPtr from, IntPtr to);

        // Mono gives a DynamicMethod its runtime method in CreateDynMethod and keeps
        // the handle in _mhandle; the public MethodHandle throws for DynamicMethods.
        private static readonly MethodInfo? createDynMethod =
            typeof(DynamicMethod).GetMethod("CreateDynMethod", BindingFlags.Instance | BindingFlags.NonPublic);
        private static readonly FieldInfo? dynamicMethodHandle =
            typeof(DynamicMethod).GetField("_mhandle", BindingFlags.Instance | BindingFlags.NonPublic);

        // Mono frees a DynamicMethod's code once the object is collected, so the
        // replacement each patched method runs stays referenced here.
        private static readonly Dictionary<MethodBase, MethodBase> replacements = new Dictionary<MethodBase, MethodBase>();

        /// <summary>Makes calls to <paramref name="original"/> run <paramref name="replacement"/>,
        /// which takes the same arguments (the instance first, for instance methods).</summary>
        public static void Detour(MethodBase original, MethodBase replacement)
        {
            if (original is null)
                throw new ArgumentNullException(nameof(original));
            if (replacement is null)
                throw new ArgumentNullException(nameof(replacement));

            IntPtr from = RuntimeHandle(original);
            IntPtr to = RuntimeHandle(replacement);
            lock (replacements)
            {
                if (RedirectMethod(from, to) != 0)
                    throw new NotSupportedException(
                        $"{Describe(original)} can't be patched on iOS: it was compiled ahead of time, and only interpreted methods can be redirected");
                replacements[original] = replacement;
            }
            Console.WriteLine($"[StS2Mono] patched {Describe(original)}");
        }

        /// <summary>Patch classes that Harmony.PatchAll skipped because they failed.</summary>
        public static int SkippedPatchClasses { get; private set; }

        /// <summary>Called by Harmony.PatchAll (rewritten by harmonypatch) when one patch class
        /// fails. Harmony would stop there and leave the rest of the mod unpatched; mods built
        /// for a newer game often target a few methods this one lacks, so the class is skipped
        /// and the others still get patched.</summary>
        public static void SkipFailedPatchClass(Exception exception, Type patchClass)
        {
            SkippedPatchClasses++;
            Console.WriteLine($"[StS2Mono] skipped patch class {patchClass.FullName}: {Reason(exception)}");
        }

        /// <summary>Harmony.Patch / PatchProcessor.Patch calls that failed and were skipped.</summary>
        public static int SkippedPatches { get; private set; }

        /// <summary>Called by PatchProcessor.Patch (rewritten by harmonypatch) when it fails, for
        /// example when a transpiler made for a newer game can't find its code here. The
        /// exception would end the caller's initialization (BaseLib patches this way); instead
        /// the failure is logged, nothing is patched, and Patch returns null.</summary>
        public static void SkipFailedPatch(Exception exception, MethodBase? original)
        {
            SkippedPatches++;
            Console.WriteLine($"[StS2Mono] skipped a patch of {(original is null ? "(no method)" : Describe(original))}: {Reason(exception)}");
        }

        /// <summary>Replaces HarmonyLib.AccessTools.GetTypesFromAssembly. A mod built for a newer
        /// game has types that don't load here (their base types or interfaces are missing).
        /// On CoreCLR, GetTypes then throws ReflectionTypeLoadException, which Harmony handles;
        /// Mono often throws a plain TypeLoadException for the whole assembly, so the types are
        /// then taken one by one, leaving out those that fail.</summary>
        public static Type[] GetTypesFromAssembly(Assembly assembly)
        {
            try
            {
                return assembly.GetTypes();
            }
            catch (ReflectionTypeLoadException e)
            {
                return Array.FindAll(e.Types, t => t != null)!;
            }
            catch (Exception e)
            {
                return GetTypesOneByOne(assembly, e);
            }
        }

        private const BindingFlags DeclaredMembers =
            BindingFlags.DeclaredOnly | BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Static;

        private static Type[] GetTypesOneByOne(Assembly assembly, Exception getTypesFailure)
        {
            var types = new List<Type>();
            int failed = 0;
            foreach (Module module in assembly.GetModules())
            {
                // TypeDef rows from 2 (row 1 is <Module>) until the token is out of range.
                for (int row = 2; row < 0x00FFFFFF; row++)
                {
                    Type? type;
                    try
                    {
                        type = module.ResolveType(0x02000000 | row);
                    }
                    catch (ArgumentException)
                    {
                        break; // past the last TypeDef
                    }
                    catch (Exception)
                    {
                        failed++;
                        continue;
                    }
                    try
                    {
                        // Mono hands out a type whose loading failed as a placeholder: its
                        // base type is missing, and it throws once really used, as listing
                        // its methods does.
                        if (type == null || (type.BaseType == null && !type.IsInterface && type != typeof(object)))
                        {
                            failed++;
                            continue;
                        }
                        type.GetMethods(DeclaredMembers);
                        types.Add(type);
                    }
                    catch (Exception)
                    {
                        failed++;
                    }
                }
            }
            Console.WriteLine($"[StS2Mono] {failed} types in {assembly.GetName().Name} can't be loaded on this game version and are left out ({getTypesFailure.GetType().Name}: {getTypesFailure.Message})");
            return types.ToArray();
        }

        private static string Reason(Exception exception)
        {
            string reason = $"{exception.GetType().Name}: {exception.Message}";
            for (Exception? inner = exception.InnerException; inner != null; inner = inner.InnerException)
                reason += $" <- {inner.GetType().Name}: {inner.Message}";
            return reason.Length > 600 ? reason.Substring(0, 600) + "..." : reason;
        }

        /// <summary>Replaces HarmonyLib.AccessTools.Identifiable, which asks MonoMod.Core
        /// for a canonical MethodInfo: one method reached through different types gives
        /// different MethodInfo objects, so use the one from its declaring type.</summary>
        public static MethodInfo Identifiable(MethodInfo method)
        {
            if (method is null || method is DynamicMethod || method.DeclaringType is null || method.ReflectedType == method.DeclaringType)
                return method!;
            return MethodBase.GetMethodFromHandle(method.MethodHandle, method.DeclaringType.TypeHandle) as MethodInfo ?? method;
        }

        private static IntPtr RuntimeHandle(MethodBase method)
        {
            if (method is DynamicMethod dynamicMethod)
            {
                if (createDynMethod is null || dynamicMethodHandle is null)
                    throw new NotSupportedException("this runtime's DynamicMethod has no CreateDynMethod/_mhandle");
                createDynMethod.Invoke(dynamicMethod, null); // compiles the IL once; later calls do nothing
                return ((RuntimeMethodHandle)dynamicMethodHandle.GetValue(dynamicMethod)!).Value;
            }
            return method.MethodHandle.Value;
        }

        private static string Describe(MethodBase method) =>
            method.DeclaringType is null ? method.Name : $"{method.DeclaringType.FullName}.{method.Name}";
    }
}
