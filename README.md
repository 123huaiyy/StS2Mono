# StS2Mono

让杀戮尖塔2 iOS 移植版改用 Mono 解释器运行游戏的 C# 代码，而不是打包时的 NativeAOT 版本，这样游戏自带的 mod 加载器就能加载 dll 模组。

## 原理

移植版用的是官方 Godot 4.5.1 模板。它启动 .NET 时会先在 `Library/Caches/data_sts2_ios_arm64/` 里依次找 `libhostfxr.so`、`libcoreclr.so`、`libmonosgen-2.0.so`，都找不到才用 NativeAOT。`StS2Mono.dylib` 作为 LiveContainer 模块加载时，会把 `libmonosgen-2.0.so` 链接到自己，Godot 就会调用它导出的 `coreclr_initialize` / `coreclr_create_delegate`，由 Mono 解释执行 `Documents/dotnet/` 里的 IL 程序集。

## 编译

推送到 `main` 或手动运行 Actions 里的 “Build StS2Mono”。产物 `StS2Mono` 里有：

- `StS2Mono.dylib`：Mono 运行时 + 预编译的 System.Private.CoreLib + 桥接代码
- `dotnet/`：与之配套的 .NET 基础类库

本仓库不包含任何游戏文件，编译只用到微软公开的 NuGet 运行时包。

## 使用

1. 在 LiveContainer 的模块里导入 `StS2Mono.dylib`，替换原来的 `StS2Mod.dylib`（它的 mods 软链接功能已经包含在内）。
2. 把 `dotnet/` 里的文件，连同游戏的 IL 版程序集（`sts2.dll`、`GodotSharp.dll` 等），一起放进游戏数据目录的 `Documents/dotnet/`。
3. 启动游戏。日志在 `Documents/dotnet/bridge.log` 和 `Documents/dotnet/console.log`。
4. 在 `Documents/dotnet/` 里放一个名为 `verbose` 的空文件，可以输出更详细的 Mono 日志。
5. 想退回原来的 NativeAOT：在 `Documents/dotnet/` 里放一个名为 `DISABLE` 的空文件。
