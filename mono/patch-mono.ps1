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
