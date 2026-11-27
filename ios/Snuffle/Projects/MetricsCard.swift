import SnuffleKit
import SwiftUI

/// How a project's numbers are counted, in project settings and the connect flow: who counts as a user (its own
/// page) and revenue. Which numbers the card shows is the card editor's.
struct MetricsCard: View {
    @Binding var project: Project
    @State private var editingCounting = false
    @State private var source = Analytics.CountingSource.manual

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if project.posthog != nil {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(String(localized: "用户怎么算"))
                    CardGroup {
                        Button { editingCounting = true } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("数字怎么算").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
                                    Text(verbatim: project.countingSummary).font(.system(size: 12)).foregroundStyle(Palette.ink2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.forward").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.ink2)
                            }
                            .frame(minHeight: 60)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("countingRow")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(String(localized: "收入用哪边的数"))
                CountingChoices(kind: .revenue, project: $project)
            }
        }
        .sheet(isPresented: $editingCounting) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Spacer()
                            Button("完成") { editingCounting = false }
                                .font(.system(size: 15, weight: .heavy))
                                .foregroundStyle(Palette.paper)
                                .padding(.horizontal, 18)
                                .frame(minHeight: 44)
                                .background(Palette.ink, in: Capsule())
                        }
                        PageTitle(title: String(localized: "数字怎么算"), subtitle: String(localized: "\(project.name) 的累计、活跃和新增都按这里算。"))
                        CountingOptions(project: $project, source: $source)
                    }
                    .padding(16)
                }
                .sheetPage()
            }
        }
    }
}
