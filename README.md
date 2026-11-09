 StS2Mono

让杀戮尖塔2 iOS 移植版改用 Mono 解释器运行游戏的 C# 代码，而不是打包时的 NativeAOT 版本，这样游戏自带的 mod 加载器就能加载 dll 模组，包括用 Harmony 打补丁的模组。

## 原理

移植版用的是官方 Godot 4.5.1 模板。它启动 .NET 时会先在 `Library/Caches/data_sts2_ios_arm64/` 里依次找 `libhostfxr.so`、`libcoreclr.so`、`libmonosgen-2.0.so`，都找不到才用 NativeAOT。`StS2Mono.dylib` 作为 LiveContainer 模块加载时，会把 `libmonosgen-2.0.so` 链接到自己，Godot 就会调用它导出的 `coreclr_initialize` / `coreclr_create_delegate`，由 Mono 解释执行 `Documents/dotnet/` 里的 IL 程序集。

### Harmony

Harmony 平时靠改写方法的机器码来打补丁（MonoMod.Core），iOS 上的解释器没有可改写的机器码。所以：

- `mono/patch-mono.ps1` 给 Mono 加了 `mono_interp_redirect_method`：让对一个解释执行的方法的调用改去执行另一个方法（Harmony 生成的替换方法）。同一个补丁还修了 arm64 上解释器把 bool 等窄整数返回给原生代码时没有扩展到 32 位的问题。
- `harmony/StS2Mono.Harmony` 是适配层；`harmony/harmonypatch` 用 Cecil 改写 Lib.Harmony 2.4.2 的 `0Harmony.dll`（游戏自带的就是这个版本），让 `PatchTools.DetourMethod` 和 `AccessTools.Identifiable` 改走适配层。
- 解释器的内联必须关掉（桥接代码设置了 `MONO_INTERPRETER_OPTIONS=-inline`），否则被内联的方法不会经过重定向。
- 预编译（AOT）的 System.Private.CoreLib 里的方法不能打补丁，其它程序集（游戏、GodotSharp、其它基础类库）都可以。

## 编译

推送到 `main` 或手动运行 Actions 里的 “Build StS2Mono”：

1. `mono/build-mono.sh` 从 dotnet/runtime v9.0.22 源码编译打过补丁的 Mono（iOS 版和用于测试的 macOS 版），结果会缓存。
2. `harmony/build.sh` 生成 `StS2Mono.Harmony.dll` 和改写后的 `0Harmony.dll`。
3. `harmony/test-desktop.sh` 在 macOS 上用全解释模式的 Mono 跑 `harmony/HarmonyTest`，检查各种补丁（前缀、后缀、转译器、构造函数、虚方法、结构体、委托、泛型、反向补丁、取消补丁等）。
4. `build.sh` 编译桥接代码。产物 `StS2Mono` 里有：
   - `StS2Mono.dylib`：Mono 运行时 + 预编译的 System.Private.CoreLib + 桥接代码
   - `dotnet/`：配套的 .NET 基础类库，以及 `0Harmony.dll`（改写版）和 `StS2Mono.Harmony.dll`

本仓库不包含任何游戏文件，编译只用到微软的源码和公开的 NuGet 包（Lib.Harmony 以 MIT 许可证发布）。

## 使用

1. 在 LiveContainer 的模块里导入 `StS2Mono.dylib`，替换原来的 `StS2Mod.dylib`（它的 mods 软链接功能已经包含在内）。
2. 把 `dotnet/` 里的文件，连同游戏的 IL 版程序集（`sts2.dll`、`GodotSharp.dll` 等），一起放进游戏数据目录的 `Documents/dotnet/`。`0Harmony.dll` 要用这里的改写版。
3. 启动游戏。日志在 `Documents/dotnet/bridge.log` 和 `Documents/dotnet/console.log`（每个 Harmony 补丁会记一行 `[StS2Mono] patched ...`）。
4. 在 `Documents/dotnet/` 里放一个名为 `verbose` 的空文件，可以输出更详细的 Mono 日志。
5. 想退回原来的 NativeAOT：在 `Documents/dotnet/` 里放一个名为 `DISABLE` 的空文件。
