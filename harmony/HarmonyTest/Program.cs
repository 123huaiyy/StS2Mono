// Checks that Harmony patches work through StS2Mono's interpreter redirect.
// harmony/test-desktop.sh runs it on StS2Mono's Mono build for macOS with
// everything interpreted and inlining off, the way the game runs on iOS.
// Prints PASS/FAIL for each check; the exit code is 1 if any check failed.

using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Reflection.Emit;
using System.Runtime.InteropServices;
using HarmonyLib;

namespace StS2Mono.HarmonyTest
{
    public static class Targets
    {
        public static int Square(int x) => x * x;
        public static bool IsEven(int x) => x % 2 == 0;
        public static int Ten() => 10;
        public static int Hot(int x) => x + 1;
        public static int FibCalls;
        public static int Fib(int n) => n < 2 ? n : Fib(n - 1) + Fib(n - 2);
        public static string Mix(int a, double b, Point p, string s, long l) => $"{a}|{b}|{p.X},{p.Y}|{s}|{l}";
        public static Point MakePoint(int x) => new Point(x, x);
        public static Big MakeBig(long x) => new Big { A = x, B = x, C = x, D = x, E = x };
        public static int CompareAscending(int a, int b) => a.CompareTo(b);
        public static int Throws() => throw new InvalidOperationException("thrown by the original");
        public static int Limit => 10;
    }

    public class Counter
    {
        private readonly int value = 5;
        public int Get() => value;
    }

    public class Animal
    {
        public virtual string Speak() => "...";
    }

    public class Dog : Animal
    {
        public override string Speak() => "woof";
    }

    public class Cat : Animal
    {
    }

    public struct Point
    {
        public int X, Y;
        public Point(int x, int y) { X = x; Y = y; }
        public int Sum() => X + Y;
    }

    public struct Big
    {
        public long A, B, C, D, E;
    }

    public class Widget
    {
        public int Size;
        public Widget(int size) { Size = size; }
    }

    public interface IShape
    {
        int Corners();
    }

    public class Square : IShape
    {
        public int Corners() => 4;
    }

    public class Box<T>
    {
        private readonly T value;
        public Box(T value) { this.value = value; }
        public T Get() => value;
    }

    public abstract class Shape
    {
        private int sides;
        protected Shape(int sides) { this.sides = sides; }
        public int Sides => sides;
    }

    public sealed class Triangle : Shape
    {
        public Triangle() : base(3) { }
    }

    // The replacement is a copy of Triangle's constructor, which calls Shape's protected
    // one, and the postfix writes Shape's private field: neither is visible to a method
    // outside these classes, so the runtime must not check access for replacements.
    [HarmonyPatch(typeof(Triangle), MethodType.Constructor)]
    internal static class TrianglePatch
    {
        private static void Postfix(ref int ___sides) => ___sides += 10;
    }

    // Built on a library type that test-desktop.sh removes, like a mod type built on a
    // BaseLib type the installed BaseLib lacks. Never touched directly here.
    public class Orphan : Missing.MissingBase
    {
    }

    public class VirtualBase
    {
        public virtual void Use(Missing.MissingParam param) { }
    }

    // Overrides a method whose signature uses a type missing at run time, like a mod relic
    // overriding BeforeSideTurnStart(ICombatState) on a game without ICombatState: the type
    // itself loads, but building its method table fails once it's cast or instantiated.
    public class BadOverride : VirtualBase
    {
        public override void Use(Missing.MissingParam param) { }
    }

    internal static class FailingTranspiler
    {
        public static IEnumerable<CodeInstruction> Transpiler(IEnumerable<CodeInstruction> instructions) =>
            throw new InvalidOperationException("can't find the code this transpiler was made for");
    }

    // A target this game build doesn't have: PatchAll must skip it and go on.
    [HarmonyPatch(typeof(Targets), "MethodFromANewerVersion")]
    internal static class MissingTargetPatch
    {
        private static void Prefix() { }
    }

    [HarmonyPatch(typeof(Targets), nameof(Targets.Square))]
    internal static class SquarePatch
    {
        private static void Prefix(ref int x) => x += 1;
    }

    [HarmonyPatch(typeof(Targets), nameof(Targets.Square))]
    internal static class SquareOriginal
    {
        [HarmonyReversePatch]
        public static int Call(int x) => throw new NotImplementedException("reverse patch stub");
    }

    [HarmonyPatch(typeof(Counter), nameof(Counter.Get))]
    internal static class CounterPatch
    {
        private static void Postfix(ref int __result) => __result += 100;
    }

    [HarmonyPatch(typeof(Targets), nameof(Targets.IsEven))]
    internal static class IsEvenPatch
    {
        private static bool Prefix(int x, ref bool __result)
        {
            if (x != 3)
                return true;
            __result = true; // and skip the original
            return false;
        }
    }

    [HarmonyPatch(typeof(Animal), nameof(Animal.Speak))]
    internal static class SpeakPatch
    {
        private static void Postfix(ref string __result) => __result += "!";
    }

    [HarmonyPatch(typeof(Point), nameof(Point.Sum))]
    internal static class PointSumPatch
    {
        private static void Postfix(ref Point __instance, ref int __result) => __result = __instance.X * 10 + __instance.Y;
    }

    [HarmonyPatch(typeof(Widget), MethodType.Constructor, typeof(int))]
    internal static class WidgetPatch
    {
        private static void Postfix(Widget __instance) => __instance.Size *= 2;
    }

    [HarmonyPatch(typeof(Targets), nameof(Targets.Limit), MethodType.Getter)]
    internal static class LimitPatch
    {
        private static void Postfix(ref int __result) => __result = 99;
    }

    [HarmonyPatch(typeof(Targets), nameof(Targets.Ten))]
    internal static class TenPatch
    {
        private static IEnumerable<CodeInstruction> Transpiler(IEnumerable<CodeInstruction> instructions)
        {
            foreach (CodeInstruction instruction in instructions)
            {
                if (instruction.LoadsConstant(10))
                {
                    instruction.opcode = OpCodes.Ldc_I4;
                    instruction.operand = 20;
                }
                yield return instruction;
            }
        }
    }

    [HarmonyPatch(typeof(Targets), nameof(Targets.Hot))]
    internal static class HotPatch
    {
        private static void Postfix(ref int __result) => __result += 1000;
    }

    [HarmonyPatch(typeof(Square), nameof(Square.Corners))]
    internal static class CornersPatch
    {
        private static void Postfix(ref int __result) => __result += 1;
    }

    [HarmonyPatch]
    internal static class BoxIntPatch
    {
        private static MethodBase TargetMethod() => typeof(Box<int>).GetMethod(nameof(Box<int>.Get))!;
        private static void Postfix(ref int __result) => __result += 1;
    }

    [HarmonyPatch]
    internal static class BoxStringPatch
    {
        private static MethodBase TargetMethod() => typeof(Box<string>).GetMethod(nameof(Box<string>.Get))!;
        private static void Postfix(ref string __result) => __result += "!";
    }

    [HarmonyPatch(typeof(Targets), nameof(Targets.Fib))]
    internal static class FibPatch
    {
        private static void Prefix() => Targets.FibCalls++;
    }

    [HarmonyPatch(typeof(Targets), nameof(Targets.Mix))]
    internal static class MixPatch
    {
        private static void Prefix(ref double b, ref Point p)
        {
            b *= 2;
            p.Y += 1;
        }
    }

    [HarmonyPatch(typeof(Targets), nameof(Targets.MakePoint))]
    internal static class MakePointPatch
    {
        private static void Postfix(ref Point __result) => __result.Y = 7;
    }

    [HarmonyPatch(typeof(Targets), nameof(Targets.MakeBig))]
    internal static class MakeBigPatch
    {
        private static void Postfix(ref Big __result) => __result.E = 42;
    }

    [HarmonyPatch(typeof(Targets), nameof(Targets.CompareAscending))]
    internal static class ComparePatch
    {
        private static void Postfix(ref int __result) => __result = -__result;
    }

    [HarmonyPatch(typeof(Targets), nameof(Targets.Throws))]
    internal static class ThrowsPatch
    {
        private static Exception? Finalizer(Exception? __exception) => null;
    }

    public static class Program
    {
        private static int failures;

        private static void Check(string name, Func<object?> actual, object? expected)
        {
            object? value;
            try
            {
                value = actual();
            }
            catch (Exception e)
            {
                value = $"{e.GetType().Name}: {e.Message}";
            }
            bool ok = Equals(value, expected);
            if (!ok)
                failures++;
            Console.WriteLine(ok ? $"PASS  {name}: {value}" : $"FAIL  {name}: {value} (expected {expected})");
        }

        public static int Main()
        {
            bool mono = Type.GetType("Mono.RuntimeStructs") != null;
            string generator = Environment.GetEnvironmentVariable("MONOMOD_DMDType") ?? "default";
            Console.WriteLine($"{RuntimeInformation.FrameworkDescription} on {(mono ? "Mono" : "CoreCLR")}, {RuntimeInformation.ProcessArchitecture}, replacements made by the {generator} generator");

            // Made before patching: a delegate, and a method hot enough to have
            // tiered up in the interpreter.
            Func<int, int> squareBeforePatching = Targets.Square;
            Comparison<int> compare = Targets.CompareAscending;
            int hot = 0;
            for (int i = 0; i < 5000; i++)
                hot += Targets.Hot(i);

            var harmony = new Harmony("sts2mono.harmonytest");
            try
            {
                harmony.PatchAll(typeof(Program).Assembly);
            }
            catch (Exception e)
            {
                Console.WriteLine($"FAIL  PatchAll threw {e}");
                return 1;
            }

            Check("patch class with a missing target skipped", () => InterpDetour.SkippedPatchClasses, 1);
            Check("static method, prefix changes an argument", () => Targets.Square(3), 16);
            Check("delegate made before patching", () => squareBeforePatching(3), 16);
            Check("reflection invoke", () => typeof(Targets).GetMethod(nameof(Targets.Square))!.Invoke(null, new object[] { 3 }), 16);
            Check("reverse patch runs the original", () => SquareOriginal.Call(3), 9);
            Check("instance method, postfix", () => new Counter().Get(), 105);
            Check("bool set by a prefix that skips the original", () => Targets.IsEven(3), true);
            Check("bool true from the original", () => Targets.IsEven(4), true);
            Check("bool false from the original", () => Targets.IsEven(5), false);
            Check("inherited virtual method", () => new Cat().Speak(), "...!");
            Check("virtual call through the base type", () => ((Animal)new Cat()).Speak(), "...!");
            Check("override isn't patched", () => new Dog().Speak(), "woof");
            Check("struct instance method", () => new Point(1, 2).Sum(), 12);
            Check("constructor", () => new Widget(21).Size, 42);
            Check("constructor calling a protected base constructor, private field", () => new Triangle().Sides, 13);
            Check("property getter", () => Targets.Limit, 99);
            Check("transpiler", () => Targets.Ten(), 20);
            Check("method that tiered up before patching", () => Targets.Hot(1), 1002);
            Check("interface call", () => ((IShape)new Square()).Corners(), 5);
            Check("generic class over int", () => new Box<int>(41).Get(), 42);
            Check("generic class over long isn't patched", () => new Box<long>(41).Get(), 41L);
            Check("generic class over string", () => new Box<string>("hi").Get(), "hi!");
            Check("recursion", () => { Targets.FibCalls = 0; return Targets.Fib(5); }, 5);
            Check("recursive calls go through the patch", () => Targets.FibCalls, 15);
            Check("mixed argument types", () => Targets.Mix(1, 1.5, new Point(2, 3), "s", 1L << 40), $"1|3|2,4|s|{1L << 40}");
            Check("small struct result", () => Targets.MakePoint(2).Y, 7);
            Check("large struct result", () => Targets.MakeBig(5).E + Targets.MakeBig(5).A, 47L);
            Check("delegate called by List.Sort", () => { var list = new List<int> { 2, 3, 1 }; list.Sort(compare); return string.Join(",", list); }, "3,2,1");
            Check("finalizer swallows the exception", () => Targets.Throws(), 0);
            Check("patched methods known to Harmony", () => harmony.GetPatchedMethods().Count(), 19);
            Check("types that can't load are left out, the others found", () =>
            {
                Type[] types = AccessTools.GetTypesFromAssembly(typeof(Program).Assembly);
                return $"{types.Any(t => t.Name == nameof(Targets))} {types.Any(t => t.Name == "Orphan")} {types.Any(t => t.Name == "BadOverride")}";
            }, "True False False");
            Check("Harmony.Patch with a failing transpiler returns null", () => harmony.Patch(
                AccessTools.Method(typeof(Targets), nameof(Targets.Ten)),
                transpiler: new HarmonyMethod(typeof(FailingTranspiler), nameof(FailingTranspiler.Transpiler))) == null, true);
            Check("failed Harmony.Patch counted", () => InterpDetour.SkippedPatches, 1);
            Check("the method's earlier patch still works", () => Targets.Ten(), 20);

            harmony.UnpatchAll(harmony.Id);
            Check("unpatched static method", () => Targets.Square(3), 9);
            Check("unpatched delegate", () => squareBeforePatching(3), 9);
            Check("unpatched instance method", () => new Counter().Get(), 5);
            Check("unpatched constructor", () => new Widget(21).Size, 21);
            Check("unpatched original still throws", () => Targets.Throws(), "InvalidOperationException: thrown by the original");

            Console.WriteLine(failures == 0 ? $"all checks passed ({hot})" : $"{failures} check(s) failed");
            return failures == 0 ? 0 : 1;
        }
    }
}
