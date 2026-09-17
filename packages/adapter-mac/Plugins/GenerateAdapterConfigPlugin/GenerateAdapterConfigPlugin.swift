import PackagePlugin

/// Generates `AdapterBuildConfig.swift` from `config/adapter.properties`
/// at build time.
///
/// ADR 0005 requires every adapter's relay URL and licensing endpoint to
/// come from build-time configuration, never a literal inline in source.
/// AGP gives `packages/adapter-android` a generated-`BuildConfig`
/// mechanism as an arbitrary Gradle task
/// (`app/build.gradle.kts`'s `generateAdapterBuildConfig`); SwiftPM has
/// no built-in equivalent, so this package's own build-tool plugin fills
/// the same role. A `BuildToolPlugin` only *describes* a command for
/// SwiftPM to run before compiling, so the actual properties-file
/// parsing and code generation lives in `generate.sh`, a plain shell
/// script next to this file, rather than in this plugin's own Swift code.
///
/// Considered and rejected: an `.xcconfig` (ADR 0005's own illustrative
/// example for Swift) has nowhere to land its values into compiled Swift
/// constants without an `Info.plist` and a `Bundle` to read it from -
/// this package is a plain SwiftPM library with no app target or bundle
/// yet, so that mechanism doesn't apply here. A checked-in Swift file
/// with the values written directly into it was the other option the
/// issue offered, but that's a self-hoster editing and committing Swift
/// source to change an endpoint, materially worse than editing a
/// `.properties` file - and closer to "hardcoded" than ADR 0005 asks
/// for. This plugin keeps the self-hosting experience (edit
/// `config/adapter.properties`, rebuild) identical to
/// `adapter-android`'s.
@main
struct GenerateAdapterConfigPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let propertiesFile = context.package.directory.appending(subpath: "config/adapter.properties")
        let generatorScript = context.package.directory.appending(
            subpath: "Plugins/GenerateAdapterConfigPlugin/generate.sh"
        )
        let outputDirectory = context.pluginWorkDirectory.appending(subpath: "GeneratedAdapterConfig")
        let outputFile = outputDirectory.appending(subpath: "AdapterBuildConfig.swift")

        return [
            .prebuildCommand(
                displayName: "Generate AdapterBuildConfig.swift from config/adapter.properties",
                executable: Path("/bin/sh"),
                arguments: [generatorScript.string, propertiesFile.string, outputFile.string],
                // A prebuildCommand (rather than buildCommand) because
                // the output file's existence can't be declared upfront
                // for SwiftPM's dependency graph - it's produced by this
                // very command, on every build, from whatever
                // config/adapter.properties currently contains.
                outputFilesDirectory: outputDirectory
            ),
        ]
    }
}
