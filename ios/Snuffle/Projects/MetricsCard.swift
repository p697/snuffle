import SnuffleKit
import SwiftUI

/// Whose activity counts, and how new users and revenue are counted, each choice with today's number. Shared by the connect flow and the editor;
/// which numbers the card shows is the card editor's.
struct MetricsCard: View {
    @Binding var project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if project.posthog != nil {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(String(localized: "算哪些人"))
                    ScopeOptions(project: $project)
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(String(localized: "新增用户"))
                    CountingOptions(kind: .newUsers, project: $project)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(String(localized: "收入"))
                CountingOptions(kind: .revenue, project: $project)
            }
        }
    }
}
