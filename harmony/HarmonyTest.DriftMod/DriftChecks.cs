using System;
using System.Collections.Generic;
using StS2Mono.HarmonyTest.Missing;

namespace StS2Mono.HarmonyTest.DriftMod
{
    // Calls compiled against the first version of Drifted. Each runs in a lambda of its
    // own, since a call the interpreter can't bind fails the whole method it's in.
    public static class DriftChecks
    {
        public static List<(string Name, Func<object?> Actual, object? Expected)> All() => new()
        {
            ("constructor gets the new parameter's default", () => new Drifted(5).Count, 5),
            ("result that was dropped comes back null", () =>
            {
                Entry entry = new Drifted(1).AddEmpty(3);
                return $"{Drifted.Last} {entry == null}";
            }, "added 3 True"),
            ("new parameters get their defaults", () => new Drifted(1).Describe(4), $"4 True ! 1.5 Big True {1L << 40}"),
            ("new result is dropped", () =>
            {
                new Drifted(1).Clear();
                return Drifted.Last;
            }, "cleared"),
            ("number result that was dropped comes back zero", () =>
            {
                int n = new Drifted(1).Measure();
                return $"{n} {Drifted.Last}";
            }, "0 measured"),
            ("result of a more derived type", () => new Drifted(1).Make().Name, "derived"),
            ("argument to a widened parameter", () => Drifted.Take(new DerivedEntry()), "derived"),
            ("int argument to an enum parameter", () => Drifted.Pick(1), "Big"),
        };
    }
}
