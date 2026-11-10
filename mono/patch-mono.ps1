param(
    [Parameter(Mandatory = $true)][string]$RuntimeRoot   # a dotnet/runtime checkout at tag v9.0.22
)

# Patches Mono for StS2Mono:
#  1. An interpreter method redirect (mono_interp_redirect_method), which is how
#     Harmony patches are applied without rewriting executable memory.
#  2. Narrow integer return values extended to 32 bits when the interpreter
#     returns to native code on arm64, as Apple's ABI requires (a C# `false`
#     could otherwise arrive in Godot as `true`).
#  3. No member access checks in the interpreter (see transform.c below).
#  4. Reading the parameters of a method whose parameter is marked as having a
#     default value but has none no longer aborts (see reflection.c below).
#  5. Thread dumps name interpreted frames (see threads.c below).
#  6. A method reference that differs from the method only by custom modifiers
#     (an `init` setter against a plain one) still binds (see loader.c below).
#  7. Code loaded from the mods folder is told it runs on Android, so mods that
#     turn their Harmony patches off on iOS keep them (see transform.c, mods).
#  8. A call from a mod to a game method whose signature changed between game
#     versions is adapted instead of failing (see transform.c, drift).
# Every anchor must occur exactly once, so a changed upstream file fails loudly.

$ErrorActionPreference = "Stop"

function Edit-Source([string]$RelativePath, [object[]]$Edits) {
    $path = Join-Path $RuntimeRoot $RelativePath
    $text = [IO.File]::ReadAllText($path)
    $crlf = $text.Contains("`r`n")
    $text = $text.Replace("`r`n", "`n")
    foreach ($edit in $Edits) {
        $find = $edit[0].Replace("`r`n", "`n")
        $replace = $edit[1].Replace("`r`n", "`n")
        $count = ([regex]::Matches($text, [regex]::Escape($find))).Count
        if ($count -ne 1) {
            throw "$RelativePath : expected one match, found $count, for:`n$find"
        }
        $text = $text.Replace($find, $replace)
    }
    if ($crlf) { $text = $text.Replace("`n", "`r`n") }
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false))
    Write-Host "patched $RelativePath ($($Edits.Count) edits)"
}

$T = "`t"

Edit-Source "src/mono/mono/mini/interp/interp-internals.h" @(
    @(
        "${T}long opcounts;`n#endif`n};`n`n/* Used for localloc memory allocation */",
        "${T}long opcounts;`n#endif`n${T}/* StS2Mono: when set, calls to this method run REDIRECT instead (mono_interp_redirect_method). */`n${T}InterpMethod *redirect;`n};`n`n/* Used for localloc memory allocation */"
    ),
    @(
        "mono_interp_jit_call_supported (MonoMethod *method, MonoMethodSignature *sig);",
        "mono_interp_jit_call_supported (MonoMethod *method, MonoMethodSignature *sig);`n`nMONO_API int`nmono_interp_redirect_method (MonoMethod *from, MonoMethod *to);"
    )
)

Edit-Source "src/mono/mono/mini/interp/interp.c" @(
    @(
        "static MonoException* do_transform_method (InterpMethod *imethod, InterpFrame *method, ThreadContext *context);`n",
        @"
static MonoException* do_transform_method (InterpMethod *imethod, InterpFrame *method, ThreadContext *context);

/* StS2Mono: a method redirected by mono_interp_redirect_method runs its target instead. */
static inline InterpMethod*
interp_follow_redirect (InterpMethod *imethod)
{
${T}InterpMethod *target = imethod->redirect;
${T}return G_LIKELY (!target) ? imethod : target;
}

"@.Replace("`r`n", "`n")
    ),
    # Entry from compiled code: the arguments are laid out for the original method,
    # which has the same layout as the redirect target.
    @(
        "${T}frame.imethod = data->rmethod;`n",
        "${T}frame.imethod = interp_follow_redirect (data->rmethod);`n"
    ),
    @(
        "${T}newsp = (stackval*)ALIGN_TO (newsp, MINT_STACK_ALIGNMENT);`n${T}context->stack_pointer = (guchar*)newsp;`n${T}g_assert (context->stack_pointer < context->stack_end);`n",
        "${T}newsp = (stackval*)ALIGN_TO (newsp, MINT_STACK_ALIGNMENT);`n${T}context->stack_pointer = (guchar*)newsp;`n${T}g_assert (context->stack_pointer < context->stack_end);`n${T}frame.imethod = interp_follow_redirect (frame.imethod);`n"
    ),
    # Virtual, delegate, calli and vararg calls meet here, after their arguments
    # (unboxed this, delegate target) were set up for the original method.
    @(
        "jit_call:`n${T}${T}${T}{`n",
        "jit_call:`n${T}${T}${T}cmethod = interp_follow_redirect (cmethod);`n${T}${T}${T}{`n"
    ),
    @(
        "interp_call:`n",
        "interp_call:`n${T}${T}${T}cmethod = interp_follow_redirect (cmethod);`n"
    ),
    @(
        "`n${T}${T}${T}if (frame->imethod->prof_flags & MONO_PROFILER_CALL_INSTRUMENTATION_TAIL_CALL)",
        "`n${T}${T}${T}new_method = interp_follow_redirect (new_method);`n${T}${T}${T}if (frame->imethod->prof_flags & MONO_PROFILER_CALL_INSTRUMENTATION_TAIL_CALL)"
    ),
    @(
        "static gpointer`ninterp_get_interp_method (MonoMethod *method)`n{",
        @"
/*
 * StS2Mono: make calls to FROM run TO instead, or undo that when TO is NULL.
 * This is how Harmony patches are applied on iOS, where executable memory can't
 * be rewritten. TO must take FROM's arguments, with the instance as an explicit
 * first parameter for instance methods, which is what Harmony generates.
 * Returns -1 when FROM runs as AOT code, since those calls bypass the interpreter.
 * A method that already tiered up has a second InterpMethod that callers were
 * patched to use, so it gets the redirect too. A redirected method never runs its
 * own code again, so it can't tier up afterwards.
 * Callers come through a P/Invoke, so in GC safe mode; the lookups take runtime
 * locks that switch to GC safe mode themselves when contended, which Mono aborts
 * on unless the thread is back in GC unsafe mode first.
 */
int
mono_interp_redirect_method (MonoMethod *from, MonoMethod *to)
{
${T}int result = -1;
${T}MONO_ENTER_GC_UNSAFE;
${T}MonoMethodSignature *sig = mono_method_signature_internal (from);
${T}if (sig && !mono_interp_jit_call_supported (from, sig)) {
${T}${T}InterpMethod *source = mono_interp_get_imethod (from);
${T}${T}InterpMethod *target = to ? mono_interp_get_imethod (to) : NULL;
${T}${T}if (target == source)
${T}${T}${T}target = NULL;
${T}${T}mono_memory_barrier ();
${T}${T}source->redirect = target;
${T}${T}if (source->optimized_imethod)
${T}${T}${T}source->optimized_imethod->redirect = target;
${T}${T}result = 0;
${T}}
${T}MONO_EXIT_GC_UNSAFE;
${T}return result;
}

static gpointer
interp_get_interp_method (MonoMethod *method)
{
"@.Replace("`r`n", "`n")
    )
)

Edit-Source "src/mono/mono/mini/interp/transform.c" @(
    @(
        "static void`ninterp_generate_mae_throw (TransformData *td, MonoMethod *method, MonoMethod *target_method)`n{",
        @"
/*
 * StS2Mono: the interpreter doesn't enforce member visibility. Mods are usually
 * compiled against a publicized game assembly and declare [IgnoresAccessChecksTo],
 * which CoreCLR honors and Mono doesn't, and the replacements Harmony generates call
 * protected base constructors and private members. A game has nothing to protect
 * with these checks, so they're off: calls, ldftn, and field access.
 */
#define STS2MONO_CHECK_ACCESS 0

static void
interp_generate_mae_throw (TransformData *td, MonoMethod *method, MonoMethod *target_method)
{
"@.Replace("`r`n", "`n")
    ),
    @(
        "${T}if (check_visibility && target_method && !mono_method_can_access_method (method, target_method))",
        "${T}if (STS2MONO_CHECK_ACCESS && check_visibility && target_method && !mono_method_can_access_method (method, target_method))"
    ),
    @(
        "${T}if (!method->skip_visibility && !mono_method_can_access_field (method, field)) {",
        "${T}if (STS2MONO_CHECK_ACCESS && !method->skip_visibility && !mono_method_can_access_field (method, field)) {"
    ),
    @(
        "${T}${T}${T}${T}if (!mono_method_can_access_method (method, m))`n${T}${T}${T}${T}${T}interp_generate_mae_throw (td, method, m);",
        "${T}${T}${T}${T}if (STS2MONO_CHECK_ACCESS && !mono_method_can_access_method (method, m))`n${T}${T}${T}${T}${T}interp_generate_mae_throw (td, method, m);"
    )
)

# The replacements Harmony generates copy the original's parameter attributes,
# so a parameter with a default value (float volume = 1f) is marked HasDefault,
# but the value itself isn't copied. Mono then found no constant, read its type
# as 0, and mono_class_from_mono_type_internal aborted the process. Stack traces
# read every frame's parameters, so a game error or exception logged while such
# a replacement was on the stack crashed the game. A missing value now counts as
# no default value; dynamic methods, which have no MethodDef row to look the
# value up by, are treated the same way instead of failing an assertion.
Edit-Source "src/mono/mono/metadata/reflection.c" @(
    @(
        "${T}if (!(sig_param->attrs & PARAM_ATTRIBUTE_HAS_DEFAULT) ||`n${T}    (method->wrapper_type != MONO_WRAPPER_NONE && method->wrapper_type != MONO_WRAPPER_DYNAMIC_METHOD)) {",
        "${T}/* StS2Mono: !blob_type_enum, a parameter marked HasDefault without a value. */`n${T}if (!(sig_param->attrs & PARAM_ATTRIBUTE_HAS_DEFAULT) || !blob_type_enum ||`n${T}    (method->wrapper_type != MONO_WRAPPER_NONE && method->wrapper_type != MONO_WRAPPER_DYNAMIC_METHOD)) {"
    ),
    @(
        "${T}idx = mono_method_get_index (method);`n${T}g_assert (idx != 0);`n`n${T}param_index = mono_metadata_get_method_params (image, idx, &lastp);",
        "${T}idx = mono_method_get_index (method);`n${T}/* StS2Mono: a dynamic method has no MethodDef row, so no default values to read. */`n${T}if (!idx)`n${T}${T}return;`n`n${T}param_index = mono_metadata_get_method_params (image, idx, &lastp);"
    )
)

# Mods built for newer versions of the game call property setters that became
# `init` there. Such a setter's signature differs from this version's plain one
# only by modreq(IsExternalInit) on its return type, so the call didn't bind and
# threw MissingMethodException (an ancient event mod's dialogue never loaded, and
# the event showed no options). When nothing in the class matches exactly, a
# method that matches but for custom modifiers is used.
Edit-Source "src/mono/mono/metadata/loader.c" @(
    ,@(
        "`n${T}if (matched) {`n${T}${T}if (i < mcount)",
        @"

${T}/* StS2Mono: see patch-mono.ps1, loader.c. */
${T}if (!matched && sig->call_convention != MONO_CALL_VARARG) {
${T}${T}i = -1;
${T}${T}iter = NULL;
${T}${T}while ((m = mono_class_get_methods (klass, &iter))) {
${T}${T}${T}++i;
${T}${T}${T}if (!((fqname && !strcmp (m->name, fqname)) ||
${T}${T}${T}      (qname && !strcmp (m->name, qname)) ||
${T}${T}${T}      (name && !strcmp (m->name, name))))
${T}${T}${T}${T}continue;
${T}${T}${T}MonoMethodSignature *msig = mono_method_signature_checked (m, error);
${T}${T}${T}if (!is_ok (error))
${T}${T}${T}${T}return NULL;
${T}${T}${T}if (msig && mono_metadata_signature_equal_ignore_custom_modifier (sig, msig)) {
${T}${T}${T}${T}matched = TRUE;
${T}${T}${T}${T}break;
${T}${T}${T}}
${T}${T}}
${T}}

${T}if (matched) {
${T}${T}if (i < mcount)
"@.Replace("`r`n", "`n").TrimEnd("`n")
    )
)

# transform.c, mods: mods decide from the platform whether they can patch the game.
# iOS builds of Godot games normally run ahead-of-time compiled code that can't be
# patched, so mods take iOS (or RuntimeFeature.IsDynamicCodeCompiled being false,
# which it is in this interpreter) to mean "no Harmony" and run without their
# patches (P3Makoto: "runtime code patching unavailable (platform iOS) -> effects
# disabled"). StS2Mono patches through the interpreter, as the game's Android port
# does through its JIT, so code loaded from the mods folder is told it runs on
# Android: its calls to Godot.OS.GetName and HasFeature and to
# OperatingSystem.IsIOS and IsAndroid go to the StS2Mono_* methods tools/ilpatch
# adds to GodotSharp's Godot.OS, and IsDynamicCodeCompiled is true for it. The
# substitution is made when a method is compiled to interpreter code, so it costs
# nothing per call. The game itself still sees iOS.
Edit-Source "src/mono/mono/mini/interp/transform.c" @(
    @(
        "/* Return TRUE if call transformation is finished */`nstatic gboolean`ninterp_handle_intrinsics (",
        @"
#include <mono/metadata/image-internals.h>
#include <mono/metadata/loader-internals.h>

/* StS2Mono: see patch-mono.ps1, transform.c, mods. */
static gboolean
sts2mono_is_mod_method (MonoMethod *method)
{
${T}const char *file = method ? mono_image_get_filename (m_class_get_image (method->klass)) : NULL;
${T}return file && (strstr (file, "/Documents/mods/") || strstr (file, ".app/mods/"));
}

static MonoMethod *
sts2mono_mod_substitute (MonoMethod *target)
{
${T}static const char *const subs [][4] = {
${T}${T}/* namespace, class, method, method in Godot.OS that mods call instead */
${T}${T}{ "Godot", "OS", "GetName", "StS2Mono_GetName" },
${T}${T}{ "Godot", "OS", "HasFeature", "StS2Mono_HasFeature" },
${T}${T}{ "System", "OperatingSystem", "IsIOS", "StS2Mono_IsIOS" },
${T}${T}{ "System", "OperatingSystem", "IsAndroid", "StS2Mono_IsAndroid" },
${T}};
${T}MonoClass *klass = target->klass;
${T}for (guint i = 0; i < G_N_ELEMENTS (subs); i++) {
${T}${T}if (strcmp (target->name, subs [i][2]) || strcmp (m_class_get_name (klass), subs [i][1]) || strcmp (m_class_get_name_space (klass), subs [i][0]))
${T}${T}${T}continue;
${T}${T}MonoImage *godot = m_class_get_image (klass);
${T}${T}if (strcmp (subs [i][0], "Godot"))
${T}${T}${T}godot = mono_image_loaded_internal (mono_alc_get_default (), "GodotSharp");
${T}${T}if (!godot)
${T}${T}${T}return NULL;
${T}${T}ERROR_DECL (class_error);
${T}${T}MonoClass *os = mono_class_from_name_checked (godot, "Godot", "OS", class_error);
${T}${T}mono_error_cleanup (class_error);
${T}${T}if (!os)
${T}${T}${T}return NULL;
${T}${T}ERROR_DECL (method_error);
${T}${T}MonoMethod *substitute = mono_class_get_method_from_name_checked (os, subs [i][3], mono_method_signature_internal (target)->param_count, 0, method_error);
${T}${T}mono_error_cleanup (method_error);
${T}${T}/* NULL with a GodotSharp that tools/ilpatch didn't patch: the call stays as it is. */
${T}${T}return substitute;
${T}}
${T}return NULL;
}

/* Return TRUE if call transformation is finished */
static gboolean
interp_handle_intrinsics (
"@.Replace("`r`n", "`n").TrimEnd("`n")
    ),
    @(
        "${T}${T}if (!strcmp (tm, `"get_IsDynamicCodeCompiled`"))`n${T}${T}${T}*op = MINT_LDC_I4_0;",
        "${T}${T}if (!strcmp (tm, `"get_IsDynamicCodeCompiled`"))`n${T}${T}${T}*op = sts2mono_is_mod_method (td->method) ? MINT_LDC_I4_1 : MINT_LDC_I4_0;"
    ),
    @(
        "${T}} else {`n${T}${T}csignature = mono_method_signature_internal (target_method);`n${T}}`n`n${T}if (calli && csignature->param_count == 0 && csignature->call_convention == MONO_CALL_THISCALL) {",
        @"
${T}} else {
${T}${T}csignature = mono_method_signature_internal (target_method);
${T}}

${T}/* StS2Mono: see patch-mono.ps1, transform.c, mods. */
${T}if (target_method && !calli && sts2mono_is_mod_method (method)) {
${T}${T}MonoMethod *substitute = sts2mono_mod_substitute (target_method);
${T}${T}if (substitute) {
${T}${T}${T}target_method = substitute;
${T}${T}${T}csignature = mono_method_signature_internal (target_method);
${T}${T}}
${T}}

${T}if (calli && csignature->param_count == 0 && csignature->call_convention == MONO_CALL_THISCALL) {
"@.Replace("`r`n", "`n").TrimEnd("`n")
    )
)

# transform.c, drift: mods are built against the game version their authors had, and
# the game changes method signatures between versions: a return value dropped
# (MegaAnimationState.AddEmptyAnimation returned a MegaTrackEntry, now nothing),
# parameters added with default values, a parameter or result type widened or
# narrowed within a class hierarchy, an int parameter turned into an enum. A call
# compiled against the other signature threw MissingMethodException, which took down
# the whole calling method. When a method from the mods folder calls (call, callvirt
# or newobj) a method that can't be found, the interpreter now looks in the target
# class and its bases for a method of that name it can call instead: same instance or
# static kind, each argument the caller passes fits the parameter (same type, or a
# class or interface the parameter accepts, or the same integer type under an enum),
# any further parameters have default values (numbers, booleans, enums, strings,
# null), and the result fits what the caller expects, or there was none before
# (the caller's result is then null or zero), or the caller ignores one now (it's
# dropped). The closest one wins (fewest added parameters, then fewest inexact
# types); if two tie, nothing is bound and the call fails as before. The default
# values are pushed before the call and the result fixed up after it, all while the
# method is compiled, so the adapted call costs what a normal one does. Each adapted
# call site is logged once ("StS2Mono: ... bound to ..."). A type that's missing
# altogether still can't be helped.
Edit-Source "src/mono/mono/mini/interp/transform.c" @(
    @(
        "/* Return FALSE if error, including inline failure */`nstatic gboolean`ninterp_transform_call (TransformData *td, MonoMethod *method, MonoMethod *target_method, MonoGenericContext *generic_context, MonoClass *constrained_class, gboolean readonly, MonoError *error, gboolean check_visibility, gboolean save_last_error, gboolean tailcall)`n{",
        @"
/* StS2Mono: see patch-mono.ps1, transform.c, drift. */
#include <mono/metadata/tokentype.h>

#define STS2MONO_DRIFT_MAX_DEFAULTS 8

typedef enum {
${T}STS2MONO_RET_SAME,
${T}STS2MONO_RET_POP,
${T}STS2MONO_RET_DEFAULT
} Sts2MonoRetFix;

typedef struct {
${T}MonoType *type;
${T}guint8 kind; /* MONO_TYPE_* of the constant, MONO_TYPE_CLASS for null */
${T}gint64 i;
${T}double r;
${T}const char *chars; /* a string's UTF-16 characters, in the metadata */
${T}guint32 chars_len;
} Sts2MonoDefault;

typedef struct {
${T}int extra;
${T}Sts2MonoDefault defaults [STS2MONO_DRIFT_MAX_DEFAULTS];
${T}Sts2MonoRetFix ret;
${T}MonoType *ret_type;
} Sts2MonoDrift;

/* The stack type a value of TYPE is pushed as, or -1 for a struct or a byref. */
static int
sts2mono_simple_stack_type (MonoType *type)
{
${T}if (m_type_is_byref (type))
${T}${T}return -1;
${T}int mt = mono_mint_type (type);
${T}if (mt == MINT_TYPE_VT)
${T}${T}return -1;
${T}return stack_type [mt];
}

/* 0 if REQUESTED and ACTUAL are the same type, 1 if a value fits (an argument the
 * parameter, a result the caller), -1 if not. */
static int
sts2mono_type_compat (MonoType *requested, MonoType *actual, gboolean is_param)
{
${T}if (mono_metadata_type_equal_full (requested, actual, MONO_TYPE_EQ_FLAGS_SIG_ONLY | MONO_TYPE_EQ_FLAG_IGNORE_CMODS))
${T}${T}return 0;
${T}if (m_type_is_byref (requested) || m_type_is_byref (actual))
${T}${T}return -1;
${T}if (MONO_TYPE_IS_REFERENCE (requested) && MONO_TYPE_IS_REFERENCE (actual)) {
${T}${T}MonoClass *req = mono_class_from_mono_type_internal (requested);
${T}${T}MonoClass *act = mono_class_from_mono_type_internal (actual);
${T}${T}gboolean fits = is_param ? mono_class_is_assignable_from_internal (act, req) : mono_class_is_assignable_from_internal (req, act);
${T}${T}return fits ? 1 : -1;
${T}}
${T}/* An enum and its underlying integer type, either way round. */
${T}int rs = sts2mono_simple_stack_type (requested);
${T}if (rs == STACK_TYPE_I4 || rs == STACK_TYPE_I8) {
${T}${T}MonoType *ru = mono_type_get_underlying_type (requested);
${T}${T}MonoType *au = mono_type_get_underlying_type (actual);
${T}${T}if (!m_type_is_byref (au) && ru->type == au->type)
${T}${T}${T}return 1;
${T}}
${T}return -1;
}

/* The default value of parameter INDEX (from 0) of M, when it has one that can be pushed. */
static gboolean
sts2mono_param_default (MonoMethod *m, int index, MonoType *type, Sts2MonoDefault *out)
{
${T}MonoImage *image = m_class_get_image (m->klass);
${T}if (!m->token || mono_metadata_token_table (m->token) != MONO_TABLE_METHOD || image_is_dynamic (image))
${T}${T}return FALSE;
${T}int st = sts2mono_simple_stack_type (type);
${T}if (st < 0)
${T}${T}return FALSE;
${T}guint32 last;
${T}guint32 first = mono_metadata_get_method_params (image, mono_metadata_token_index (m->token), &last);
${T}if (!first)
${T}${T}return FALSE;
${T}for (guint32 row = first; row < last; row++) {
${T}${T}guint32 cols [MONO_PARAM_SIZE];
${T}${T}mono_metadata_decode_row (&image->tables [MONO_TABLE_PARAM], row - 1, cols, MONO_PARAM_SIZE);
${T}${T}if (cols [MONO_PARAM_SEQUENCE] != (guint32)index + 1)
${T}${T}${T}continue;
${T}${T}if (!(cols [MONO_PARAM_FLAGS] & PARAM_ATTRIBUTE_HAS_DEFAULT))
${T}${T}${T}return FALSE;
${T}${T}guint32 constant = mono_metadata_get_constant_index (image, MONO_TOKEN_PARAM_DEF | row, 0);
${T}${T}if (!constant)
${T}${T}${T}return FALSE;
${T}${T}guint32 ccols [MONO_CONSTANT_SIZE];
${T}${T}mono_metadata_decode_row (&image->tables [MONO_TABLE_CONSTANT], constant - 1, ccols, MONO_CONSTANT_SIZE);
${T}${T}const char *value = mono_metadata_blob_heap (image, ccols [MONO_CONSTANT_VALUE]);
${T}${T}guint32 len = mono_metadata_decode_blob_size (value, &value);
${T}${T}const guchar *blob = (const guchar *)value;
${T}${T}out->type = type;
${T}${T}out->kind = (guint8)ccols [MONO_CONSTANT_TYPE];
${T}${T}out->i = 0;
${T}${T}out->r = 0;
${T}${T}out->chars = NULL;
${T}${T}out->chars_len = 0;
${T}${T}switch (out->kind) {
${T}${T}case MONO_TYPE_BOOLEAN:
${T}${T}case MONO_TYPE_U1: out->i = blob [0]; break;
${T}${T}case MONO_TYPE_I1: out->i = (gint8)blob [0]; break;
${T}${T}case MONO_TYPE_CHAR:
${T}${T}case MONO_TYPE_U2: out->i = read16 (blob); break;
${T}${T}case MONO_TYPE_I2: out->i = (gint16)read16 (blob); break;
${T}${T}case MONO_TYPE_I4: out->i = (gint32)read32 (blob); break;
${T}${T}case MONO_TYPE_U4: out->i = (guint32)read32 (blob); break;
${T}${T}case MONO_TYPE_I8:
${T}${T}case MONO_TYPE_U8: out->i = (gint64)read64 (blob); break;
${T}${T}case MONO_TYPE_R4: { float f; readr4 (blob, &f); out->r = f; break; }
${T}${T}case MONO_TYPE_R8: readr8 (blob, &out->r); break;
${T}${T}case MONO_TYPE_CLASS: break; /* null */
${T}${T}case MONO_TYPE_STRING:
${T}${T}${T}out->chars = value;
${T}${T}${T}out->chars_len = len / 2;
${T}${T}${T}break;
${T}${T}default:
${T}${T}${T}return FALSE;
${T}${T}}
${T}${T}/* A null or a string goes to a reference parameter, a number to a number. */
${T}${T}if (out->kind == MONO_TYPE_CLASS || out->kind == MONO_TYPE_STRING)
${T}${T}${T}return st == STACK_TYPE_O;
${T}${T}return st != STACK_TYPE_O;
${T}}
${T}return FALSE;
}

/* How well M can stand in for a method with signature SIG, lower is closer; -1 if it can't. */
static int
sts2mono_drift_score (MonoMethodSignature *sig, MonoMethod *m, Sts2MonoDrift *d)
{
${T}ERROR_DECL (error);
${T}MonoMethodSignature *msig = mono_method_signature_checked (m, error);
${T}if (!msig) {
${T}${T}mono_error_cleanup (error);
${T}${T}return -1;
${T}}
${T}if (msig->hasthis != sig->hasthis || msig->generic_param_count || msig->call_convention == MONO_CALL_VARARG)
${T}${T}return -1;
${T}if (msig->param_count < sig->param_count || msig->param_count - sig->param_count > STS2MONO_DRIFT_MAX_DEFAULTS)
${T}${T}return -1;
${T}int score = 0;
${T}for (int i = 0; i < sig->param_count; i++) {
${T}${T}int c = sts2mono_type_compat (sig->params [i], msig->params [i], TRUE);
${T}${T}if (c < 0)
${T}${T}${T}return -1;
${T}${T}score += c;
${T}}
${T}d->extra = msig->param_count - sig->param_count;
${T}for (int i = 0; i < d->extra; i++) {
${T}${T}int index = sig->param_count + i;
${T}${T}if (!sts2mono_param_default (m, index, msig->params [index], &d->defaults [i]))
${T}${T}${T}return -1;
${T}}
${T}score += 4 * d->extra;
${T}d->ret_type = sig->ret;
${T}gboolean requested_void = sig->ret->type == MONO_TYPE_VOID;
${T}gboolean actual_void = msig->ret->type == MONO_TYPE_VOID;
${T}if (requested_void && actual_void) {
${T}${T}d->ret = STS2MONO_RET_SAME;
${T}} else if (requested_void) {
${T}${T}d->ret = STS2MONO_RET_POP;
${T}${T}score += 2;
${T}} else if (actual_void) {
${T}${T}if (sts2mono_simple_stack_type (sig->ret) < 0)
${T}${T}${T}return -1;
${T}${T}d->ret = STS2MONO_RET_DEFAULT;
${T}${T}score += 2;
${T}} else {
${T}${T}int c = sts2mono_type_compat (sig->ret, msig->ret, FALSE);
${T}${T}if (c < 0)
${T}${T}${T}return -1;
${T}${T}d->ret = STS2MONO_RET_SAME;
${T}${T}score += c;
${T}}
${T}return score;
}

/* The method a call from CALLER to member reference TOKEN can be bound to, or NULL. */
static MonoMethod *
sts2mono_find_drifted (MonoMethod *caller, guint32 token, Sts2MonoDrift *drift)
{
${T}MonoImage *image = m_class_get_image (caller->klass);
${T}/* A dynamic method's (Harmony's replacements') tokens index its wrapper data, not metadata. */
${T}if (caller->wrapper_type != MONO_WRAPPER_NONE || caller->dynamic || image_is_dynamic (image))
${T}${T}return NULL;
${T}if (mono_metadata_token_table (token) != MONO_TABLE_MEMBERREF)
${T}${T}return NULL;
${T}guint32 cols [MONO_MEMBERREF_SIZE];
${T}mono_metadata_decode_row (&image->tables [MONO_TABLE_MEMBERREF], mono_metadata_token_index (token) - 1, cols, MONO_MEMBERREF_SIZE);
${T}if ((cols [MONO_MEMBERREF_CLASS] & MONO_MEMBERREF_PARENT_MASK) != MONO_MEMBERREF_PARENT_TYPEREF)
${T}${T}return NULL;
${T}ERROR_DECL (error);
${T}MonoClass *klass = mono_class_get_checked (image, MONO_TOKEN_TYPE_REF | (cols [MONO_MEMBERREF_CLASS] >> MONO_MEMBERREF_PARENT_BITS), error);
${T}if (!klass || !is_ok (error) || mono_class_is_gtd (klass) || mono_class_is_ginst (klass)) {
${T}${T}mono_error_cleanup (error);
${T}${T}return NULL;
${T}}
${T}const char *name = mono_metadata_string_heap (image, cols [MONO_MEMBERREF_NAME]);
${T}const char *ptr = mono_metadata_blob_heap (image, cols [MONO_MEMBERREF_SIGNATURE]);
${T}mono_metadata_decode_blob_size (ptr, &ptr);
${T}if ((*ptr & 0x0f) == 0x06) /* a field */
${T}${T}return NULL;
${T}MonoMethodSignature *sig = mono_metadata_parse_method_signature_full (image, NULL, 0, ptr, NULL, error);
${T}if (!sig || !is_ok (error) || sig->generic_param_count || sig->call_convention == MONO_CALL_VARARG) {
${T}${T}mono_error_cleanup (error);
${T}${T}return NULL;
${T}}
${T}MonoMethod *best = NULL;
${T}int best_score = G_MAXINT;
${T}gboolean tie = FALSE;
${T}Sts2MonoDrift d;
${T}for (MonoClass *k = klass; k && !best; k = m_class_get_parent (k)) {
${T}${T}gpointer iter = NULL;
${T}${T}MonoMethod *m;
${T}${T}while ((m = mono_class_get_methods (k, &iter))) {
${T}${T}${T}if (strcmp (m->name, name))
${T}${T}${T}${T}continue;
${T}${T}${T}int score = sts2mono_drift_score (sig, m, &d);
${T}${T}${T}if (score < 0)
${T}${T}${T}${T}continue;
${T}${T}${T}if (score < best_score) {
${T}${T}${T}${T}best = m;
${T}${T}${T}${T}best_score = score;
${T}${T}${T}${T}*drift = d;
${T}${T}${T}${T}tie = FALSE;
${T}${T}${T}} else if (score == best_score) {
${T}${T}${T}${T}tie = TRUE;
${T}${T}${T}}
${T}${T}}
${T}}
${T}return tie ? NULL : best;
}

static void
sts2mono_push_const (TransformData *td, MonoType *type, guint8 kind, gint64 i, double r, const char *chars, guint32 chars_len)
{
${T}gboolean real = kind == MONO_TYPE_R4 || kind == MONO_TYPE_R8;
${T}switch (sts2mono_simple_stack_type (type)) {
${T}case STACK_TYPE_O: {
${T}${T}MonoString *s = NULL;
${T}${T}if (chars) {
${T}${T}${T}ERROR_DECL (str_error);
${T}${T}${T}s = mono_string_new_utf16_checked ((const gunichar2 *)chars, chars_len, str_error);
${T}${T}${T}if (!is_ok (str_error)) {
${T}${T}${T}${T}mono_error_cleanup (str_error);
${T}${T}${T}${T}s = NULL;
${T}${T}${T}}
${T}${T}}
${T}${T}if (s) {
${T}${T}${T}/* The compiled code points at the string; a pinned handle keeps it alive and in place. */
${T}${T}${T}mono_gchandle_new_internal ((MonoObject *)s, TRUE);
${T}${T}${T}interp_add_ins (td, MINT_LDSTR);
${T}${T}${T}td->last_ins->data [0] = get_data_item_index (td, s);
${T}${T}${T}push_type (td, STACK_TYPE_O, mono_defaults.string_class);
${T}${T}} else {
${T}${T}${T}interp_add_ins (td, MINT_LDNULL);
${T}${T}${T}push_type (td, STACK_TYPE_O, NULL);
${T}${T}}
${T}${T}break;
${T}}
${T}case STACK_TYPE_I4: {
${T}${T}gint32 v = real ? (gint32)r : (gint32)i;
${T}${T}interp_add_ins (td, MINT_LDC_I4);
${T}${T}WRITE32_INS (td->last_ins, 0, &v);
${T}${T}push_simple_type (td, STACK_TYPE_I4);
${T}${T}break;
${T}}
${T}case STACK_TYPE_I8: {
${T}${T}gint64 v = real ? (gint64)r : i;
${T}${T}interp_add_ins (td, MINT_LDC_I8);
${T}${T}WRITE64_INS (td->last_ins, 0, &v);
${T}${T}push_simple_type (td, STACK_TYPE_I8);
${T}${T}break;
${T}}
${T}case STACK_TYPE_R4: {
${T}${T}float v = real ? (float)r : (float)i;
${T}${T}interp_add_ins (td, MINT_LDC_R4);
${T}${T}WRITE32_INS (td->last_ins, 0, &v);
${T}${T}push_simple_type (td, STACK_TYPE_R4);
${T}${T}break;
${T}}
${T}case STACK_TYPE_R8: {
${T}${T}double v = real ? r : (double)i;
${T}${T}interp_add_ins (td, MINT_LDC_R8);
${T}${T}WRITE64_INS (td->last_ins, 0, &v);
${T}${T}push_simple_type (td, STACK_TYPE_R8);
${T}${T}break;
${T}}
${T}default:
${T}${T}g_assert_not_reached ();
${T}}
${T}interp_ins_set_dreg (td->last_ins, td->sp [-1].var);
}

static void
sts2mono_push_defaults (TransformData *td, MonoMethod *caller, MonoMethod *found, Sts2MonoDrift *d)
{
${T}char *from = mono_method_full_name (caller, TRUE);
${T}char *to = mono_method_full_name (found, TRUE);
${T}g_warning ("StS2Mono: %s calls a method this game version changed, bound to %s (%d default argument(s)%s)", from, to, d->extra,
${T}${T}d->ret == STS2MONO_RET_POP ? ", result dropped" : d->ret == STS2MONO_RET_DEFAULT ? ", result null or zero" : "");
${T}g_free (from);
${T}g_free (to);
${T}for (int i = 0; i < d->extra; i++) {
${T}${T}Sts2MonoDefault *v = &d->defaults [i];
${T}${T}sts2mono_push_const (td, v->type, v->kind, v->i, v->r, v->chars, v->chars_len);
${T}}
}

static gboolean
interp_transform_call_inner (TransformData *td, MonoMethod *method, MonoMethod *target_method, MonoGenericContext *generic_context, MonoClass *constrained_class, gboolean readonly, MonoError *error, gboolean check_visibility, gboolean save_last_error, gboolean tailcall);

/* Return FALSE if error, including inline failure */
static gboolean
interp_transform_call (TransformData *td, MonoMethod *method, MonoMethod *target_method, MonoGenericContext *generic_context, MonoClass *constrained_class, gboolean readonly, MonoError *error, gboolean check_visibility, gboolean save_last_error, gboolean tailcall)
{
${T}/* StS2Mono: see patch-mono.ps1, transform.c, drift. */
${T}Sts2MonoDrift drift;
${T}gboolean drifted = FALSE;
${T}if (!target_method && !constrained_class && (*td->ip == CEE_CALL || *td->ip == CEE_CALLVIRT) && sts2mono_is_mod_method (method)) {
${T}${T}guint32 token = read32 (td->ip + 1);
${T}${T}target_method = interp_get_method (method, token, m_class_get_image (method->klass), generic_context, error);
${T}${T}if (!is_ok (error)) {
${T}${T}${T}MonoMethod *found = sts2mono_find_drifted (method, token, &drift);
${T}${T}${T}if (!found)
${T}${T}${T}${T}return FALSE;
${T}${T}${T}mono_error_cleanup (error);
${T}${T}${T}error_init_reuse (error);
${T}${T}${T}target_method = found;
${T}${T}${T}drifted = TRUE;
${T}${T}${T}tailcall = FALSE;
${T}${T}${T}sts2mono_push_defaults (td, method, found, &drift);
${T}${T}}
${T}}
${T}if (!interp_transform_call_inner (td, method, target_method, generic_context, constrained_class, readonly, error, check_visibility, save_last_error, tailcall))
${T}${T}return FALSE;
${T}if (drifted && drift.ret == STS2MONO_RET_POP) {
${T}${T}interp_add_ins (td, MINT_NOP);
${T}${T}--td->sp;
${T}} else if (drifted && drift.ret == STS2MONO_RET_DEFAULT) {
${T}${T}sts2mono_push_const (td, drift.ret_type, MONO_TYPE_CLASS, 0, 0, NULL, 0);
${T}}
${T}return TRUE;
}

static gboolean
interp_transform_call_inner (TransformData *td, MonoMethod *method, MonoMethod *target_method, MonoGenericContext *generic_context, MonoClass *constrained_class, gboolean readonly, MonoError *error, gboolean check_visibility, gboolean save_last_error, gboolean tailcall)
{
"@.Replace("`r`n", "`n").TrimEnd("`n")
    ),
    @(
        "${T}${T}${T}m = interp_get_method (method, token, image, generic_context, error);`n${T}${T}${T}goto_if_nok (error, exit);`n`n${T}${T}${T}csignature = mono_method_signature_internal (m);`n${T}${T}${T}klass = m->klass;",
        @"
${T}${T}${T}m = interp_get_method (method, token, image, generic_context, error);
${T}${T}${T}/* StS2Mono: see patch-mono.ps1, transform.c, drift. */
${T}${T}${T}if (!is_ok (error) && sts2mono_is_mod_method (method)) {
${T}${T}${T}${T}Sts2MonoDrift drift;
${T}${T}${T}${T}MonoMethod *found = sts2mono_find_drifted (method, token, &drift);
${T}${T}${T}${T}if (found && drift.ret == STS2MONO_RET_SAME) {
${T}${T}${T}${T}${T}mono_error_cleanup (error);
${T}${T}${T}${T}${T}error_init_reuse (error);
${T}${T}${T}${T}${T}m = found;
${T}${T}${T}${T}${T}sts2mono_push_defaults (td, method, found, &drift);
${T}${T}${T}${T}}
${T}${T}${T}}
${T}${T}${T}goto_if_nok (error, exit);

${T}${T}${T}csignature = mono_method_signature_internal (m);
${T}${T}${T}klass = m->klass;
"@.Replace("`r`n", "`n").TrimEnd("`n")
    )
)

# The bridge asks for a thread dump when the main thread hangs. The dump named
# compiled frames only and printed "<unknown>" for interpreted ones, which on iOS
# are all of the game's and the mods' code.
# (The leading comma keeps a single edit an array of one pair; PowerShell would
# otherwise flatten it into two strings.)
Edit-Source "src/mono/mono/metadata/threads.c" @(
    ,@(
        "${T}${T}if (frame->type == FRAME_TYPE_MANAGED)`n${T}${T}${T}method = mono_jit_info_get_method (frame->ji);",
        "${T}${T}/* StS2Mono: interpreted frames too. */`n${T}${T}if (frame->type == FRAME_TYPE_MANAGED || frame->type == FRAME_TYPE_INTERP)`n${T}${T}${T}method = frame->ji ? mono_jit_info_get_method (frame->ji) : frame->method;"
    )
)

Edit-Source "src/mono/mono/mini/mini-arm64.c" @(
    @(
        "/* Set return value in the ccontext (for n2i return) */`nvoid`nmono_arch_set_native_call_context_ret",
        @"
/*
 * StS2Mono: the interpreter writes only the bytes of a narrow return value into
 * the register slot and leaves the rest of x0 as it was. On Apple platforms the
 * caller relies on the callee extending such values to 32 bits (clang tests w0),
 * so a C++ bool could read a C# false as true. Extend them here.
 */
static void
extend_narrow_int_ret (MonoMethodSignature *sig, host_mgreg_t *reg)
{
${T}switch (mini_get_underlying_type (sig->ret)->type) {
${T}case MONO_TYPE_BOOLEAN:
${T}case MONO_TYPE_U1:
${T}${T}*reg = *(guint8*)reg;
${T}${T}break;
${T}case MONO_TYPE_I1:
${T}${T}*reg = (host_mgreg_t)(gint64)*(gint8*)reg;
${T}${T}break;
${T}case MONO_TYPE_U2:
${T}case MONO_TYPE_CHAR:
${T}${T}*reg = *(guint16*)reg;
${T}${T}break;
${T}case MONO_TYPE_I2:
${T}${T}*reg = (host_mgreg_t)(gint64)*(gint16*)reg;
${T}${T}break;
${T}default:
${T}${T}break;
${T}}
}

/* Set return value in the ccontext (for n2i return) */
void
mono_arch_set_native_call_context_ret
"@.Replace("`r`n", "`n")
    ),
    @(
        "${T}${T}interp_cb->frame_arg_to_data ((MonoInterpFrameHandle)frame, sig, -1, storage);`n${T}${T}if (temp_size)`n${T}${T}${T}arg_set_val (ccontext, ainfo, storage);`n${T}}`n}",
        "${T}${T}interp_cb->frame_arg_to_data ((MonoInterpFrameHandle)frame, sig, -1, storage);`n${T}${T}if (temp_size)`n${T}${T}${T}arg_set_val (ccontext, ainfo, storage);`n${T}${T}else if (ainfo->storage == ArgInIReg)`n${T}${T}${T}extend_narrow_int_ret (sig, (host_mgreg_t*)storage);`n${T}}`n}"
    )
)
