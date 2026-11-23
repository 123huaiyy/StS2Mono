using System.Reflection;
using MegaCrit.Sts2.Core.Logging;
using MegaCrit.Sts2.Core.Models;

namespace StS2Mono.GameFixes;

// Mono runs a class's static constructor when an instance of it is created through
// reflection, also for classes marked beforefieldinit, which CoreCLR initializes only
// when a static field is first read. ModelDb.Init creates every model with
// Activator.CreateInstance, so on Mono an encounter's static fields (BowlbugsNormal:
// ModelDb.Monster<BowlbugEgg>()) are read before the monsters they name exist, and
// startup fails with KeyNotFoundException. tools/pcport makes ModelDb.Get call
// EnsureLoaded, which creates a missing model on the spot (as the game's Android build
// does), and ModelDb.Init call Init below, which keeps the models created that way and
// then puts the models back in type order, the order everything that lists them
// (and seeded picks from those lists) sees on CoreCLR.
public static class ModelDbFixes
{
    static readonly Dictionary<ModelId, AbstractModel> ContentById =
        (Dictionary<ModelId, AbstractModel>)(typeof(ModelDb).GetField("_contentById", BindingFlags.NonPublic | BindingFlags.Static)?.GetValue(null)
            ?? throw new MissingFieldException(nameof(ModelDb), "_contentById"));

    static bool _initializing;
    static bool _initialized;

    public static bool EnsureLoaded(Type type)
    {
        if (type.IsAbstract || !type.IsSubclassOf(typeof(AbstractModel)))
            return false;
        ModelId id = ModelDb.GetId(type);
        if (ContentById.ContainsKey(id))
            return true;
        AbstractModel model;
        try
        {
            model = (AbstractModel)Activator.CreateInstance(type)!;
        }
        catch (Exception e)
        {
            Log.Error($"[StS2Mono] ModelDb couldn't create {id} on demand: {(e as TargetInvocationException)?.InnerException ?? e}");
            return false;
        }
        // The static constructors that creating it ran may have registered it already;
        // the first instance stays, since those constructors keep references to it.
        ContentById.TryAdd(id, model);
        if (!_initializing)
            Log.Warn($"[StS2Mono] ModelDb created missing model {id} on demand");
        return true;
    }

    public static void Init(Type[]? injectedModelTypes)
    {
        Type[] types = injectedModelTypes ?? ModelDb.AllAbstractModelSubtypes;
        // Models created on demand before or during the first Init get their place in
        // the type order; later calls only add models.
        bool first = !_initialized;
        _initialized = true;
        _initializing = true;
        try
        {
            foreach (Type type in types)
            {
                ModelId id = ModelDb.GetId(type);
                if (ContentById.ContainsKey(id))
                    continue;
                var model = (AbstractModel)Activator.CreateInstance(type)!;
                ContentById.TryAdd(id, model);
            }
        }
        finally
        {
            _initializing = false;
        }
        if (!first)
            return;

        var ordered = new List<KeyValuePair<ModelId, AbstractModel>>(ContentById.Count);
        var seen = new HashSet<ModelId>();
        foreach (Type type in types)
        {
            ModelId id = ModelDb.GetId(type);
            if (seen.Add(id) && ContentById.TryGetValue(id, out AbstractModel? model))
                ordered.Add(new KeyValuePair<ModelId, AbstractModel>(id, model));
        }
        foreach (KeyValuePair<ModelId, AbstractModel> entry in ContentById)
        {
            if (seen.Add(entry.Key))
                ordered.Add(entry);
        }
        ContentById.Clear();
        foreach (KeyValuePair<ModelId, AbstractModel> entry in ordered)
            ContentById.Add(entry.Key, entry.Value);
    }
}
