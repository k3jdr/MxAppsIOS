//
//  SpendingCategoriesDrivers.swift
//  MxAcctMGR
//
//  Adding, editing and removing spending categories and drivers from Spending Analysis ▸ Admin (V047): the two
//  dimensions on every dollar. A category is what the money bought, with the CPI series its inflation follows; a
//  driver is why the spending changed, with the attribution effect its growth beyond inflation counts as. Both are
//  stored by a code made from the name when added, which never changes. Removing one in use moves its rules, tags (and
//  a category's lifecycle triggers) to another first (the accounts service's DELETE /spending/categories/<code> and
//  /spending/drivers/<code>, ?moveTo=).
//

import SwiftUI

/// What sets a category or driver, and the entries in it now, before it is removed.
struct SpendingUsage: Decodable {
    var code: String
    var name: String
    /// rules, tags, lifecycle triggers (a category's) → how many.
    var uses: [String: Int]
    var inUse: Int
    /// Entries of every year whose category or driver it is now.
    var entries: Int
    var amount: Double

    func list(_ order: [String]) -> String {
        let one = ["rules": "rule", "tags": "tag", "lifecycle triggers": "lifecycle trigger"]
        let parts = order.compactMap { w in uses[w].flatMap { $0 > 0 ? "\($0) \($0 == 1 ? one[w] ?? w : w)" : nil } }
        return parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts.first ?? ""
    }
}

/// The code a new category (A_Z) or driver (a_z) gets from its name unless one is typed, as the accounts service makes it.
func spendingCode(from name: String, upper: Bool) -> String {
    var out = "", gap = false
    for ch in name {
        if ch.isASCII && ch.isLetter {
            if gap && !out.isEmpty { out += "_" }
            out.append(ch)
            gap = false
        } else {
            gap = true
        }
    }
    return upper ? out.uppercased() : out.lowercased()
}

// MARK: - Categories

/// New Category… and Edit Category….
struct CategoryEditor: View {
    var setup: SpendingSetup
    /// The one changed; nil adds one.
    var category: SpendingCategory?
    var saved: (SpendingSetup) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var code = ""
    @State private var description = ""
    @State private var series = ""
    /// Percent a year.
    @State private var rate = 3.0
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        let made = spendingCode(from: name, upper: true)
        VStack(alignment: .leading, spacing: 12) {
            Text(category == nil ? "New Category" : "Edit Category").heading(.heading)
            Text("A spending category is what the money bought. Rules on expense accounts, target accounts and statement text put entries in it; its consumer price index decides how much of its change is inflation.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $name, prompt: Text("Pets, Gifts, Insurance"))
                TextField("Covers", text: $description, prompt: Text("What spending goes here"))
                if let category {
                    LabeledContent("Code", value: category.code)
                        .help("What rules, tags and lifecycle triggers store; it doesn't change")
                } else {
                    TextField("Code", text: $code, prompt: Text(made.isEmpty ? "Made from the name" : made))
                        .help("What rules, tags and lifecycle triggers store: letters and _ only, made from the name unless you type one. It can't change later.")
                }
                Picker("CPI series", selection: $series) {
                    Text("None: use the assumed rate").tag("")
                    ForEach(setup.cpiSeries) { s in Text(s.name).tag(s.code) }
                }
                .help("The consumer price index its inflation follows (FRED, in the security master)")
                TextField("Assumed inflation a year (%)", value: $rate, format: .number.precision(.fractionLength(0...2)))
                    .help("The yearly price change used when the CPI series has no values for the months compared")
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(category == nil ? "Add" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || (category == nil && made.isEmpty && code.isEmpty))
            }
        }
        .padding(18)
        .frame(width: 480)
        .onAppear {
            name = category?.name ?? ""
            description = category?.description ?? ""
            series = category?.cpiSeries ?? ""
            rate = (category?.assumedInflation ?? 0.03) * 100
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var body: [String: Any] = ["name": name, "description": description, "cpiSeries": series, "assumedInflation": rate / 100]
        do {
            if let category {
                saved(try await SpendingClient.saveCategory(category.code, body))
            } else {
                if !code.trimmingCharacters(in: .whitespaces).isEmpty { body["code"] = code }
                saved(try await SpendingClient.addCategory(body))
            }
            dismiss()
        } catch { self.error = describe(error) }
    }
}

/// Remove Category…: what sets it and what is in it now, and where its rules, tags and triggers move.
struct RemoveCategorySheet: View {
    var setup: SpendingSetup
    var category: SpendingCategory
    var saved: (SpendingSetup) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var usage: SpendingUsage?
    @State private var moveTo = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        let triggers = usage?.uses["lifecycle triggers"] ?? 0
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove \u{201C}\(category.name)\u{201D}?").heading(.heading)
            if let u = usage {
                Text(u.entries == 0 ? "No entry is in it now." : "\(u.entries) \(u.entries == 1 ? "entry" : "entries"), \(money(u.amount)) in all years, \(u.entries == 1 ? "is" : "are") in it now.")
                if u.inUse == 0 {
                    Text("No rule, tag or lifecycle trigger sets it.").fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("It is set by \(u.list(["rules", "tags", "lifecycle triggers"])). They move to the category you choose"
                         + (triggers > 0 ? " (a lifecycle trigger always has one)." : "; with Not assigned they lose their category, and their entries are Not assigned until another rule gives them one."))
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("Move them to", selection: $moveTo) {
                        Text(triggers > 0 ? "Choose…" : "Not assigned").tag("")
                        ForEach(setup.categories.filter { $0.code != category.code }) { c in Text(c.name).tag(c.code) }
                    }
                }
            } else if error == nil {
                ProgressView().controlSize(.small)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive) { Task { await remove() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || usage == nil || (triggers > 0 && moveTo.isEmpty))
            }
        }
        .padding(18)
        .frame(width: 480)
        .task {
            do { usage = try await SpendingClient.categoryUsage(category.code) } catch { self.error = describe(error) }
        }
    }

    private func remove() async {
        working = true
        defer { working = false }
        do {
            saved(try await SpendingClient.deleteCategory(category.code, moveTo: moveTo.isEmpty ? nil : moveTo))
            dismiss()
        } catch { self.error = describe(error) }
    }
}

// MARK: - Drivers

/// New Driver… and Edit Driver….
struct DriverEditor: View {
    var setup: SpendingSetup
    /// The one changed; nil adds one.
    var driver: SpendingDriver?
    var saved: (SpendingSetup) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var code = ""
    @State private var help = ""
    @State private var effect = SpendingEffect.usage
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        let made = spendingCode(from: title, upper: false)
        VStack(alignment: .leading, spacing: 12) {
            Text(driver == nil ? "New Driver" : "Edit Driver").heading(.heading)
            Text("A driver is why spending changed. Its spending's growth beyond inflation counts toward one effect of the attribution: change = inflation + usage + lifecycle + behavior + one-time + taxes.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Title", text: $title, prompt: Text("Health Event, Home Project"))
                TextField("Means", text: $help, prompt: Text("When to pick it: an illness or injury, a hospital stay"))
                if let driver {
                    LabeledContent("Code", value: driver.code)
                        .help("What rules and tags store; it doesn't change")
                } else {
                    TextField("Code", text: $code, prompt: Text(made.isEmpty ? "Made from the title" : made))
                        .help("What rules and tags store: letters and _ only, made from the title unless you type one. It can't change later.")
                }
                Picker("Counts as", selection: $effect) {
                    ForEach(SpendingEffect.allCases) { e in Text(e.rawValue).tag(e) }
                }
                Text(effect.help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(driver == nil ? "Add" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty || (driver == nil && made.isEmpty && code.isEmpty))
            }
        }
        .padding(18)
        .frame(width: 480)
        .onAppear {
            title = driver?.title ?? ""
            help = driver?.help ?? ""
            effect = driver?.effect ?? .usage
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var body: [String: Any] = ["title": title, "help": help, "effect": effect.code]
        do {
            if let driver {
                saved(try await SpendingClient.saveDriver(driver.code, body))
            } else {
                if !code.trimmingCharacters(in: .whitespaces).isEmpty { body["code"] = code }
                saved(try await SpendingClient.addDriver(body))
            }
            dismiss()
        } catch { self.error = describe(error) }
    }
}

/// Remove Driver…: what sets it and what is in it now, and where its rules and tags move (or no driver).
struct RemoveDriverSheet: View {
    var setup: SpendingSetup
    var driver: SpendingDriver
    var saved: (SpendingSetup) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var usage: SpendingUsage?
    @State private var moveTo = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove \u{201C}\(driver.title)\u{201D}?").heading(.heading)
            if let u = usage {
                Text(u.entries == 0 ? "No entry has it now." : "\(u.entries) \(u.entries == 1 ? "entry" : "entries"), \(money(u.amount)) in all years, \(u.entries == 1 ? "has" : "have") it now.")
                if u.inUse == 0 {
                    Text("No rule or tag sets it.").fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("It is set by \(u.list(["rules", "tags"])). They move to the driver you choose; with No driver they lose theirs, and their growth counts as Usage until another rule gives them one.")
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("Move them to", selection: $moveTo) {
                        Text("No driver").tag("")
                        ForEach(setup.drivers.filter { $0.code != driver.code }) { d in Text(d.title).tag(d.code) }
                    }
                }
            } else if error == nil {
                ProgressView().controlSize(.small)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive) { Task { await remove() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || usage == nil)
            }
        }
        .padding(18)
        .frame(width: 480)
        .task {
            do { usage = try await SpendingClient.driverUsage(driver.code) } catch { self.error = describe(error) }
        }
    }

    private func remove() async {
        working = true
        defer { working = false }
        do {
            saved(try await SpendingClient.deleteDriver(driver.code, moveTo: moveTo.isEmpty ? nil : moveTo))
            dismiss()
        } catch { self.error = describe(error) }
    }
}
