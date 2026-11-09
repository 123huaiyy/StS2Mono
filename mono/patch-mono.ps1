param(
    [Parameter(Mandatory = $true)][string]$RuntimeRoot   # a dotnet/runtime checkout at tag v9.0.22
)

# Patches Mono for StS2Mono:
#  1. An interpreter method redirect (mono_interp_redirect_method), which is how
#     Harmony patches are applied without rewriting executable memory.
#  2. Narrow integer return values extended to 32 bits when the interpreter
#     returns to native code on arm64, as Apple's ABI requires (a C# `false`
#     could otherwise arrive in Godot as `true`).
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
 */
int
mono_interp_redirect_method (MonoMethod *from, MonoMethod *to)
{
${T}MonoMethodSignature *sig = mono_method_signature_internal (from);
${T}if (!sig || mono_interp_jit_call_supported (from, sig))
${T}${T}return -1;
${T}InterpMethod *source = mono_interp_get_imethod (from);
${T}InterpMethod *target = to ? mono_interp_get_imethod (to) : NULL;
${T}if (target == source)
${T}${T}target = NULL;
${T}mono_memory_barrier ();
${T}source->redirect = target;
${T}if (source->optimized_imethod)
${T}${T}source->optimized_imethod->redirect = target;
${T}return 0;
}

static gpointer
interp_get_interp_method (MonoMethod *method)
{
"@.Replace("`r`n", "`n")
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
