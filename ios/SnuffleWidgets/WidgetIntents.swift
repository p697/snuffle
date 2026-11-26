import AppIntents
import SnuffleKit
import WidgetKit

/// A number a widget can show: the ones every project shares, so they add up across projects.
enum WidgetMetric: String, AppEnum {
    case newUsers, activeToday, activeWeek, activeMonth, totalUsers, online, pageviews
    case revenue, orders, mrr, activeSubscriptions, activeTrials, revenueLast28Days
    case reviewsToAnswer
    /// Added after the others: saved widget configurations keep their raw values.
    case newWeek

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "数字"

    static let caseDisplayRepresentations: [WidgetMetric: DisplayRepresentation] = [
        .newUsers: "新增用户",
        .activeToday: "今日活跃",
        .activeWeek: "7 日活跃",
        .activeMonth: "30 日活跃",
        .newWeek: "7 日新增",
        .totalUsers: "累计用户",
        .online: "此刻在线",
        .pageviews: "页面浏览",
        .revenue: "收入",
        .orders: "订单",
        .mrr: "MRR",
        .activeSubscriptions: "活跃订阅",
        .activeTrials: "试用中",
        .revenueLast28Days: "近 28 天收入",
        .reviewsToAnswer: "待回复评论"
    ]

    var metric: Metric {
        switch self {
        case .newUsers: .newUsers
        case .activeToday: .activeToday
        case .activeWeek: .activeWeek
        case .activeMonth: .activeMonth
        case .totalUsers: .totalUsers
        case .online: .online
        case .pageviews: .pageviews
        case .revenue: .revenue
        case .orders: .orders
        case .mrr: .mrr
        case .activeSubscriptions: .activeSubscriptions
        case .activeTrials: .activeTrials
        case .revenueLast28Days: .revenueLast28Days
        case .reviewsToAnswer: .reviewsToAnswer
        case .newWeek: .newWeek
        }
    }
}

/// One of the person's projects (the demo ones in demo mode), or every project added up, which is the default.
struct ProjectEntity: AppEntity {
    var id: UUID
    var name: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "项目"
    static let defaultQuery = ProjectQuery()

    /// Not a project: every project the refresh includes, added up.
    static let everyProject = ProjectEntity(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, name: "")

    var isEveryProject: Bool { id == Self.everyProject.id }

    var displayRepresentation: DisplayRepresentation {
        isEveryProject ? DisplayRepresentation(title: "全部项目") : DisplayRepresentation(title: "\(name)")
    }

    static var all: [ProjectEntity] {
        let settings = SharedContainer.settings.load() ?? AppSettings()
        let projects = settings.demoMode ? DemoWorld.projects : (SharedContainer.workspace.load()?.projects ?? [])
        return [everyProject] + projects.map { ProjectEntity(id: $0.id, name: $0.name) }
    }
}

struct ProjectQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [ProjectEntity] {
        ProjectEntity.all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ProjectEntity] {
        ProjectEntity.all
    }
}

/// What a widget shows: a big number, an optional line under it, and all projects or one.
struct TodayWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "今日"
    static let description = IntentDescription("选小组件上显示哪个数、哪个项目。")

    @Parameter(title: "大数", default: .newUsers)
    var primary: WidgetMetric

    @Parameter(title: "下面一行", default: .revenue)
    var secondary: WidgetMetric?

    @Parameter(title: "项目", default: ProjectEntity.everyProject)
    var project: ProjectEntity

}
