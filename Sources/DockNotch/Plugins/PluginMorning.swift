import AppKit
import Observation
import SwiftUI

/// Every plugin's sections in the morning window. A plugin runs only after you've allowed
/// it with the row it shows the first time, which names the command it will run; changing
/// the command asks again.
@MainActor
@Observable
final class PluginMorning: MorningProvider, MorningActionHandler {
    private(set) var isLoading = false
    private var plugins: [Result<Plugin, PluginError>] = []
    private var outputs: [String: Result<Plugin.Output, PluginError>] = [:]
    @ObservationIgnored private let avatars: AvatarCache

    init(avatars: AvatarCache) {
        self.avatars = avatars
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        plugins = await Task.detached { Plugin.discover() }.value
        let allowed = MorningSettings.allowedPlugins
        await withTaskGroup(of: (String, Result<Plugin.Output, PluginError>).self) { group in
            for case .success(let plugin) in plugins where allowed[plugin.id] == plugin.manifest.command {
                group.addTask { (plugin.id, await plugin.run()) }
            }
            for await (id, output) in group {
                outputs[id] = output
                if case .success(let output) = output {
                    avatars.preload(output.sections.flatMap { $0.rows ?? [] }.compactMap { $0.avatar.flatMap(URL.init(string:)) })
                }
            }
        }
    }

    func perform(_ url: URL) -> Bool {
        guard let (action, id) = MorningAction.parse(url), action == "allow-plugin" else { return false }
        guard case .success(let plugin)? = plugins.first(where: { (try? $0.get().id) == id }) else { return true }
        MorningSettings.allowedPlugins[plugin.id] = plugin.manifest.command
        Task { await refresh() }
        return true
    }

    var sections: [MorningSection] {
        let allowed = MorningSettings.allowedPlugins
        return plugins.flatMap { result -> [MorningSection] in
            switch result {
            case .failure(let error):
                return [Self.problem(error, title: error.plugin)]
            case .success(let plugin):
                let order = plugin.manifest.order ?? 50
                guard allowed[plugin.id] == plugin.manifest.command else {
                    return [Self.permission(for: plugin, order: order)]
                }
                switch outputs[plugin.id] {
                case nil:
                    return [MorningSection(id: "plugin:\(plugin.id)", title: plugin.manifest.name, rows: [], note: "Running…", order: order)]
                case .failure(let error)?:
                    var section = Self.problem(error, title: plugin.manifest.name)
                    section.order = order
                    return [section]
                case .success(let output)?:
                    return output.sections.enumerated().map { index, section in
                        Self.section(section, index: index, plugin: plugin, order: order)
                    }
                }
            }
        }
    }

    private static func section(_ section: Plugin.Output.Section, index: Int, plugin: Plugin, order: Int) -> MorningSection {
        let id = "plugin:\(plugin.id):\(section.id ?? String(index))"
        let rows = (section.rows ?? []).enumerated().map { offset, row in
            let lead = row.lead ?? ""
            let detail = row.detail ?? ""
            let leading: DetailModel.Row.Leading = if let avatar = row.avatar {
                .avatar(URL(string: avatar), fallback: row.symbol ?? "person.crop.circle")
            } else {
                .symbol(row.symbol ?? "circle.fill", tint(row.tint) ?? Palette.secondary)
            }
            return DetailModel.Row(
                id: "\(id):\(row.id ?? String(offset))",
                leading: leading,
                title: row.title,
                lead: lead,
                leadTint: tint(row.leadTint) ?? Palette.secondary,
                rest: lead.isEmpty || detail.isEmpty ? detail : " · \(detail)",
                url: row.url.flatMap(URL.init(string:))
            )
        }
        return MorningSection(
            id: id, title: section.title, trailing: section.trailing,
            url: section.url.flatMap(URL.init(string:)), rows: rows, note: section.note,
            order: section.order ?? order
        )
    }

    private static func permission(for plugin: Plugin, order: Int) -> MorningSection {
        let row = DetailModel.Row(
            id: "plugin:\(plugin.id):allow",
            leading: .symbol("puzzlepiece.extension.fill", Palette.amber),
            title: "Allow the \(plugin.manifest.name) plugin to run",
            lead: plugin.manifest.command,
            leadTint: Palette.amber,
            rest: " · in Plugins/\(plugin.id)",
            url: MorningAction.url("allow-plugin", plugin.id)
        )
        return MorningSection(id: "plugin:\(plugin.id)", title: plugin.manifest.name, rows: [row], order: order)
    }

    private static func problem(_ error: PluginError, title: String) -> MorningSection {
        MorningSection(
            id: "plugin:\(error.plugin)", title: title, url: Plugin.folder.appendingPathComponent(error.plugin),
            rows: [], note: error.message
        )
    }

    /// A plugin's sections from fixed output, for rendering previews and checking the schema.
    static func preview(name: String, json: String) -> [MorningSection] {
        let plugin = Plugin(id: name.lowercased(), folder: Plugin.folder, manifest: .init(name: name, command: ""))
        guard let output = try? JSONDecoder().decode(Plugin.Output.self, from: Data(json.utf8)) else {
            return [problem(PluginError(plugin: plugin.id, message: "The sample output doesn't parse"), title: name)]
        }
        return output.sections.enumerated().map { section($1, index: $0, plugin: plugin, order: 50) }
    }

    static func tint(_ name: String?) -> Color? {
        switch name?.lowercased() {
        case "green": Palette.green
        case "mint": Palette.mint
        case "red": Palette.red
        case "amber", "orange", "yellow": Palette.amber
        case "blue", "link": Palette.link
        case "primary", "white": Palette.primary
        case "secondary", "gray", "grey": Palette.secondary
        case "tertiary": Palette.tertiary
        default: nil
        }
    }
}
