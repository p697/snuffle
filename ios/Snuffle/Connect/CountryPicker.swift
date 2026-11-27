import SnuffleKit
import SwiftUI

/// The App Store storefronts an app's rating, and without a key its reviews, are read in: at least one, at most
/// `AppStoreLink.maxCountries`, since each is read on every refresh.
struct CountryPicker: View {
    @Binding var selection: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    /// Every storefront by its name in the person's language.
    private static let all: [(code: String, name: String)] = Territory.storefronts
        .map { ($0, Format.place($0) ?? $0.uppercased()) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    private var shown: [(code: String, name: String)] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? Self.all : Self.all.filter { $0.name.localizedStandardContains(query) || $0.code.localizedCaseInsensitiveContains(query) }
        // The chosen ones first, in the order they were chosen.
        return selection.compactMap { code in matching.first { $0.code == code } } + matching.filter { !selection.contains($0.code) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(shown, id: \.code) { country in
                        row(country.code, name: country.name)
                    }
                } footer: {
                    Text("最多选 \(AppStoreLink.maxCountries) 个。每个地区每次刷新都要多读一次。")
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("选择地区")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    private func row(_ code: String, name: String) -> some View {
        let chosen = selection.contains(code)
        // The last one stays: an app read in no storefront has nothing to show.
        let locked = chosen ? selection.count == 1 : selection.count >= AppStoreLink.maxCountries
        return Button {
            if chosen {
                selection.removeAll { $0 == code }
            } else {
                selection.append(code)
            }
        } label: {
            HStack {
                Text(verbatim: name).foregroundStyle(Palette.ink)
                Spacer()
                if chosen { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .opacity(locked ? 0.4 : 1)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("country-\(code)")
    }
}
