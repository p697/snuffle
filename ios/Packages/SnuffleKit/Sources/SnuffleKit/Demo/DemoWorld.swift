import Foundation

/// Fictional products used by demo mode. Every name, number and review here is made up.
public struct DemoWorld: Codable, Sendable, Equatable {
    /// What the next demo refresh brings. Tests and the demo picker set it; normal demo use stays on `.natural`.
    public enum Scenario: String, Codable, Sendable, CaseIterable {
        case natural, sale, quiet, failure
    }

    public struct Pace: Codable, Sendable, Equatable {
        /// New users over a whole day, yesterday.
        public var yesterdayTotal: Double
        /// Today's pace relative to yesterday.
        public var growth: Double
        public var salesPerMinute: Double
        public var activePerDay: Double
        public var onlineAround: Int
        /// Typical order size, so the history's daily revenue matches the project's scale.
        public var averageOrder: Double
    }

    public struct Book: Codable, Sendable, Equatable {
        public var projectId: UUID
        public var pace: Pace
        public var newUsers: Int
        public var newUsersYesterday: Int
        public var hourly: [Int]
        public var revenue: Double
        public var sales: Int
        /// Times each of the project's demo events (`DemoWorld.events`) was sent today.
        public var events: [String: Int]
        public var active: Int
        public var online: Int
        public var orders: [Order]
    }

    public var dayStart: Date
    /// The demo's own clock. Each refresh moves it forward a few minutes, never behind real time.
    public var simulatedNow: Date
    public var books: [Book]
    public var reviews: [Review]
    public var scenario: Scenario

    public static let lumenId = UUID(uuidString: "6B2B6E8A-0B4E-4F7A-9C1D-5E0B6B5D1A01")!
    public static let ferryId = UUID(uuidString: "6B2B6E8A-0B4E-4F7A-9C1D-5E0B6B5D1A02")!
    public static let atlasId = UUID(uuidString: "6B2B6E8A-0B4E-4F7A-9C1D-5E0B6B5D1A03")!
    static let demoAccount = UUID(uuidString: "6B2B6E8A-0B4E-4F7A-9C1D-5E0B6B5D1A99")!

    /// The demo projects as the app lists them.
    public static let projects: [Project] = [
        Project(
            id: lumenId, name: "Lumen Notes", tint: .ink,
            posthog: PostHogLink(accountId: demoAccount, projectId: 1, projectName: "Lumen Notes", timeZone: TimeZone.current.identifier),
            appStore: AppStoreLink(accountId: demoAccount, appId: "1", appName: "Lumen Notes", bundleId: "com.example.lumen"),
            googlePlay: GooglePlayLink(accountId: demoAccount, packageName: "com.example.lumen"),
            metrics: MetricSettings(newUsers: .event(MetricSettings.signupEvent), revenue: .posthogEvent(event: "purchase", valueProperty: "value"), excludedSurfaces: [.visitors]),
            card: CardLayout(big: [.newUsers], small: [.revenue, .installs, .reviewsToAnswer])
        ),
        Project(
            id: ferryId, name: "Pocket Ferry", tint: .coral,
            posthog: PostHogLink(accountId: demoAccount, projectId: 2, projectName: "Pocket Ferry", timeZone: TimeZone.current.identifier),
            revenueCat: RevenueCatLink(accountId: demoAccount, projectId: "demo", projectName: "Pocket Ferry"),
            appStore: AppStoreLink(accountId: demoAccount, appId: "2", appName: "Pocket Ferry", bundleId: "com.example.ferry"),
            metrics: MetricSettings(newUsers: .event(MetricSettings.signupEvent), revenue: .revenueCat, excludedSurfaces: [.visitors]),
            card: CardLayout(big: [.mrr, .newUsers], small: [.activeSubscriptions, .activeTrials, .reviewsToAnswer])
        ),
        Project(
            id: atlasId, name: "Quiet Atlas", tint: .cocoa,
            posthog: PostHogLink(accountId: demoAccount, projectId: 3, projectName: "Quiet Atlas", timeZone: TimeZone.current.identifier),
            googlePlay: GooglePlayLink(accountId: demoAccount, packageName: "com.example.atlas"),
            metrics: MetricSettings(newUsers: .firstSeen, revenue: .none, excludedSurfaces: [.visitors]),
            card: CardLayout(big: [.newUsers], small: [.activeToday, .event("paywall_viewed", people: false), .reviewsToAnswer])
        )
    ]

    /// Each demo project's surfaces, as shares of its monthly active people when website visitors are left out (so the
    /// shares of the counted surfaces add up to 1).
    static let surfaceShares: [UUID: [Surface: Double]] = [
        lumenId: [.web: 0.52, .ios: 0.27, .android: 0.18, .other: 0.03, .visitors: 1.9],
        ferryId: [.ios: 0.74, .android: 0.26, .visitors: 3.1],
        atlasId: [.android: 0.81, .ios: 0.19, .visitors: 0.6]
    ]

    /// How much bigger people-based numbers get with these surfaces than with the demo's own choice.
    static func scale(_ projectId: UUID, excluding excluded: Set<Surface>) -> Double {
        let shares = surfaceShares[projectId] ?? [:]
        let chosen = shares.filter { !excluded.contains($0.key) }.values.reduce(0, +)
        let standard = shares.filter { $0.key != .visitors }.values.reduce(0, +)
        return standard > 0 ? chosen / standard : 1
    }

    /// Each demo project's events with how often they are sent a day and the share of senders among them.
    static let events: [UUID: [(name: String, perDay: Double, peopleShare: Double)]] = [
        lumenId: [("$pageview", 61_000, 0.31), ("note_created", 18_400, 0.42), ("Application Opened", 9_800, 0.71), (MetricSettings.signupEvent, 4_900, 1), (MetricSettings.installEvent, 820, 1), ("purchase", 20, 1)],
        ferryId: [("$screen", 380, 0.2), ("ticket_viewed", 140, 0.5), (MetricSettings.signupEvent, 22, 1), ("Application Opened", 90, 0.6)],
        atlasId: [("$pageview", 1_900, 0.24), ("map_opened", 520, 0.4), ("paywall_viewed", 38, 0.8), ("route_saved", 31, 0.7)]
    ]

    static let paces: [UUID: Pace] = [
        lumenId: Pace(yesterdayTotal: 4120, growth: 1.18, salesPerMinute: 0.014, activePerDay: 33_500, onlineAround: 58, averageOrder: 62),
        ferryId: Pace(yesterdayTotal: 9, growth: 2.4, salesPerMinute: 0.0012, activePerDay: 46, onlineAround: 1, averageOrder: 2.99),
        atlasId: Pace(yesterdayTotal: 70, growth: 0.92, salesPerMinute: 0, activePerDay: 210, onlineAround: 3, averageOrder: 0)
    ]

    /// A fresh demo day at `now`, with numbers proportional to how much of the day has passed. `lateInDay` (App Store
    /// screenshots) starts the demo clock at 21:30 at the earliest, so the numbers look like a full day whenever they
    /// are taken; reviews stay relative to the real time, which is what the app shows them against.
    public static func make(now: Date, calendar: Calendar = .current, lateInDay: Bool = false, random: inout some RandomNumberGenerator) -> DemoWorld {
        let dayStart = calendar.startOfDay(for: now)
        let clock = lateInDay ? max(now, dayStart.addingTimeInterval(21.5 * 3600)) : now
        let fraction = max(0.08, clock.timeIntervalSince(dayStart) / 86_400)
        let hours = max(1, Int(clock.timeIntervalSince(dayStart) / 3600) + 1)
        let books = projects.map { project -> Book in
            let pace = paces[project.id]!
            let today = Int(pace.yesterdayTotal * pace.growth * fraction)
            let sales = Int((pace.salesPerMinute * 1440 * fraction).rounded())
            let orders = (0..<sales).map { index in
                demoOrder(project.id, at: clock.addingTimeInterval(-Double(index + 1) * 1500 * .random(in: 0.6...1.4, using: &random)), random: &random)
            }
            return Book(
                projectId: project.id,
                pace: pace,
                newUsers: today,
                newUsersYesterday: Int(pace.yesterdayTotal * fraction),
                hourly: spread(today, hours: hours, random: &random),
                revenue: project.id == ferryId ? 3.28 : orders.reduce(0) { $0 + $1.amount },
                sales: project.id == ferryId ? 1 : sales,
                events: Dictionary(uniqueKeysWithValues: (events[project.id] ?? []).map { ($0.name, Int($0.perDay * fraction)) }),
                active: Int(pace.activePerDay * min(1, fraction * 1.6)),
                online: pace.onlineAround,
                orders: orders
            )
        }
        return DemoWorld(dayStart: dayStart, simulatedNow: clock, books: books, reviews: demoReviews(now: now), scenario: .natural)
    }

    /// Moves the demo clock forward and lets new users and orders arrive at each project's pace.
    public mutating func advance(to now: Date, calendar: Calendar = .current, random: inout some RandomNumberGenerator) {
        if calendar.startOfDay(for: now) != dayStart {
            let scenario = self.scenario
            self = DemoWorld.make(now: now, calendar: calendar, random: &random)
            self.scenario = scenario
            return
        }
        // At least a few minutes pass per refresh so the demo always has something to show.
        let minutes = max(now.timeIntervalSince(simulatedNow) / 60, Double(Int.random(in: 2...15, using: &random)))
        simulatedNow = max(now, simulatedNow.addingTimeInterval(minutes * 60))
        let hours = max(1, Int(simulatedNow.timeIntervalSince(dayStart) / 3600) + 1)
        for index in books.indices {
            var book = books[index]
            let perMinute = book.pace.yesterdayTotal * book.pace.growth / 1440
            let added = scenario == .quiet ? 0 : DemoWorld.poisson(perMinute * minutes, random: &random)
            book.newUsers += added
            book.newUsersYesterday += Int(book.pace.yesterdayTotal / 1440 * minutes)
            if book.hourly.count < hours { book.hourly += Array(repeating: 0, count: hours - book.hourly.count) }
            book.hourly[book.hourly.count - 1] += added
            if scenario != .quiet {
                for event in DemoWorld.events[book.projectId] ?? [] {
                    book.events[event.name, default: 0] += DemoWorld.poisson(event.perDay / 1440 * minutes, random: &random)
                }
                book.active += DemoWorld.poisson(book.pace.activePerDay / 1440 * minutes * 0.6, random: &random)
            }
            book.online = max(0, book.pace.onlineAround + Int.random(in: -6...6, using: &random) * (book.pace.onlineAround > 10 ? 1 : 0))
            let sales: Int = switch scenario {
            case .sale: book.projectId == DemoWorld.lumenId ? 1 : 0
            case .quiet: 0
            default: DemoWorld.poisson(book.pace.salesPerMinute * minutes, random: &random)
            }
            for _ in 0..<sales {
                let order = DemoWorld.demoOrder(book.projectId, at: simulatedNow, random: &random)
                book.orders.insert(order, at: 0)
                book.revenue += order.amount
                book.sales += 1
            }
            books[index] = book
        }
    }

    /// Today's numbers for a demo project, counted the way `project` says (it may be a copy with other counting).
    public func snapshot(for project: Project) -> ProjectSnapshot? {
        guard let book = books.first(where: { $0.projectId == project.id }) else { return nil }
        let pace = book.pace
        let fraction = max(0.08, simulatedNow.timeIntervalSince(dayStart) / 86_400)
        var values: [Metric: Double] = [
            .newUsers: Double(book.newUsers),
            .activeToday: Double(book.active),
            .online: Double(book.online),
            // Long windows grow slowly through the day; enough to look alive without moving on every refresh.
            .activeWeek: (pace.activePerDay * 3.4 + Double(book.active) * 0.4).rounded(),
            .activeMonth: (pace.activePerDay * 8.1 + Double(book.active) * 0.6).rounded(),
            .totalUsers: (pace.yesterdayTotal * 260 + Double(book.newUsers)).rounded()
        ]
        // Other surfaces than the demo's own (the surfaces page previews each choice).
        let scale = DemoWorld.scale(project.id, excluding: project.metrics.surfacesLeftOut)
        for metric in [Metric.activeToday, .online, .activeWeek, .activeMonth] {
            values[metric] = values[metric].map { ($0 * scale).rounded() }
        }
        // Counted another way than the demo project does (the counting page previews each choice).
        if project.metrics.newUsers != DemoWorld.projects.first(where: { $0.id == project.id })?.metrics.newUsers {
            switch project.metrics.newUsers {
            case .firstSeen: values[.newUsers] = (Double(book.newUsers) * 2.4).rounded()
            case .event(let name):
                let share = DemoWorld.events[project.id]?.first { $0.name == name }?.peopleShare ?? 1
                values[.newUsers] = name == MetricSettings.signupEvent ? (Double(book.newUsers) * 0.45).rounded() : (Double(book.events[name] ?? 0) * share).rounded()
            }
        }
        if project.metrics.newUsers == .firstSeen { values[.newUsers] = values[.newUsers].map { ($0 * scale).rounded() } }
        for event in DemoWorld.events[project.id] ?? [] {
            let times = Double(book.events[event.name] ?? Int(event.perDay * fraction))
            values[.event(event.name, people: false)] = times
            values[.event(event.name, people: true)] = (times * event.peopleShare).rounded()
            if event.name == "$pageview" || event.name == "$screen" { values[.pageviews] = (times * scale).rounded() }
        }
        var snapshot = ProjectSnapshot(
            projectId: project.id,
            fetchedAt: simulatedNow,
            dayStart: dayStart,
            values: values,
            newUsersYesterday: book.newUsersYesterday,
            hourlyNewUsers: book.hourly,
            hourlyReadAt: simulatedNow
        )
        switch project.metrics.revenue {
        case .posthogEvent:
            snapshot[.revenue] = book.revenue
            snapshot[.orders] = Double(book.sales)
            snapshot.revenueSource = .posthog
        case .revenueCat:
            snapshot[.revenue] = book.revenue
            snapshot.revenueSource = .revenueCat
        case .none:
            break
        }
        if project.revenueCat != nil {
            snapshot[.mrr] = 87
            snapshot[.activeSubscriptions] = 47
            snapshot[.activeTrials] = 3
            snapshot[.revenueLast28Days] = 96.4
        }
        if project.hasStore {
            snapshot[.reviewsToAnswer] = Double(reviews.filter { $0.projectId == project.id && $0.needsReply }.count)
        }
        if scenario == .failure, project.id == DemoWorld.ferryId {
            snapshot.failures = [SourceFailure(platform: .revenueCat, message: SourceError.http(.revenueCat, 503, String(localized: "服务暂时不可用", bundle: .module)).localizedDescription, kind: .serverError)]
        }
        return snapshot
    }

    /// The demo project's surfaces, as the surfaces page lists them.
    public func surfaceStats(for projectId: UUID) -> [SurfaceStat] {
        guard let book = books.first(where: { $0.projectId == projectId }) else { return [] }
        let month = book.pace.activePerDay * 8.1 + Double(book.active) * 0.6
        return (DemoWorld.surfaceShares[projectId] ?? [:])
            .map { SurfaceStat(surface: $0.key, people: Int(month * $0.value)) }
            .sorted { $0.people > $1.people }
    }

    /// The demo project's events, as the event picker lists them.
    public func eventStats(for projectId: UUID) -> [EventStat] {
        (DemoWorld.events[projectId] ?? []).map { event in
            let times = Int(event.perDay * 7 * 0.93)
            return EventStat(name: event.name, people: Int(Double(times) * event.peopleShare), times: times)
        }.sorted { $0.people > $1.people }
    }

    public mutating func markReplied(_ reviewId: String, text: String, at date: Date) {
        guard let index = reviews.firstIndex(where: { $0.id == reviewId }) else { return }
        reviews[index].reply = ReviewReply(text: text, date: date, pending: reviews[index].platform == .appStore)
    }

    /// Thirty days of made-up history ending today; deterministic per project so the chart is stable.
    public func history(for projectId: UUID, days: Int, calendar: Calendar = .current) -> [DailyPoint] {
        guard let book = books.first(where: { $0.projectId == projectId }) else { return [] }
        // Seeded from the id's bytes: `hashValue` changes on every launch.
        var generator = SplitMix64(seed: UInt64(projectId.uuid.15) << 8 | UInt64(projectId.uuid.14))
        let hasRevenue = DemoWorld.projects.first(where: { $0.id == projectId })?.metrics.revenue != MetricSettings.Revenue.none
        return (0..<days).map { offset -> DailyPoint in
            let day = calendar.date(byAdding: .day, value: offset - (days - 1), to: dayStart)!
            if offset == days - 1 {
                return DailyPoint(day: day, newUsers: book.newUsers, revenue: hasRevenue ? book.revenue : nil, active: book.active)
            }
            let weekday = calendar.component(.weekday, from: day)
            let weekend = weekday == 1 || weekday == 7 ? 0.82 : 1
            let trend = 0.78 + 0.22 * Double(offset) / Double(max(1, days - 1))
            let noise = Double.random(in: 0.9...1.1, using: &generator)
            let users = Int(book.pace.yesterdayTotal * trend * weekend * noise)
            let revenue = hasRevenue ? ((book.pace.salesPerMinute * 1440 * book.pace.averageOrder * trend * noise) * 100).rounded() / 100 : nil
            return DailyPoint(day: day, newUsers: users, revenue: revenue, active: Int(book.pace.activePerDay * trend * weekend * noise))
        }
    }

    // MARK: Building blocks

    static func poisson(_ lambda: Double, random: inout some RandomNumberGenerator) -> Int {
        guard lambda > 0 else { return 0 }
        if lambda > 30 {
            // Normal approximation keeps big demo projects fast.
            let u1 = Double.random(in: 0.0001...1, using: &random), u2 = Double.random(in: 0...1, using: &random)
            let z = (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
            return max(0, Int((lambda + z * lambda.squareRoot()).rounded()))
        }
        let limit = exp(-lambda)
        var k = 0
        var p = 1.0
        repeat {
            k += 1
            p *= Double.random(in: 0...1, using: &random)
        } while p > limit
        return k - 1
    }

    static func spread(_ total: Int, hours: Int, random: inout some RandomNumberGenerator) -> [Int] {
        // Quiet nights, busy afternoons.
        let weights = (0..<hours).map { hour -> Double in
            let h = Double(hour % 24)
            return 0.35 + max(0, sin((h - 6) / 24 * 2 * .pi)) + Double.random(in: 0...0.15, using: &random)
        }
        let sum = weights.reduce(0, +)
        var result = weights.map { Int(Double(total) * $0 / sum) }
        result[result.count - 1] += total - result.reduce(0, +)
        return result
    }

    static func demoOrder(_ projectId: UUID, at date: Date, random: inout some RandomNumberGenerator) -> Order {
        let catalog: [(String, Double)] = [
            (PostHogQueries.planName("Pro", yearly: false), 20), (PostHogQueries.planName("Pro", yearly: false), 20),
            (PostHogQueries.planName("Plus", yearly: false), 40), (PostHogQueries.planName("Pro", yearly: true), 192),
            (PostHogQueries.planName("Max", yearly: false), 300)
        ]
        let countries = ["US", "JP", "HK", "SG", "DE", "GB", "KR", "TW", "FR", "CA"]
        let item = catalog.randomElement(using: &random)!
        return Order(
            id: UUID().uuidString,
            projectId: projectId,
            date: date,
            amount: item.1,
            product: item.0,
            country: countries.randomElement(using: &random)
        )
    }

    static func demoReviews(now: Date) -> [Review] {
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        return [
            Review(storeId: "d1", platform: .appStore, projectId: lumenId, rating: 1, title: "Sync lost my notes",
                   body: "After the last update two notebooks disappeared on my iPad. They are still on my phone. Please fix sync, I pay for this.",
                   author: "marta_k", territory: "POL", createdAt: ago(1.2)),
            Review(storeId: "d2", platform: .appStore, projectId: lumenId, rating: 5, title: "Finally a calm notes app",
                   body: "Fast, quiet, and the search is great. Would love a dark icon.",
                   author: "quietreader", territory: "USA", createdAt: ago(3.5)),
            Review(storeId: "d3", platform: .googlePlay, projectId: lumenId, rating: 2,
                   body: "La app se cierra cuando adjunto un PDF grande. Por lo demás me gusta mucho.",
                   author: "Diego R.", language: "es_ES", createdAt: ago(5)),
            Review(storeId: "d4", platform: .appStore, projectId: lumenId, rating: 4, title: "良い", // l10n-ignore: a Japanese review
                   body: "シンプルで使いやすいです。ウィジェットがもっと大きいと嬉しいです。", // l10n-ignore
                   author: "haru", territory: "JPN", createdAt: ago(9)),
            Review(storeId: "d5", platform: .appStore, projectId: lumenId, rating: 3, title: "Subscription price",
                   body: "Good app but the yearly price went up without notice. A student discount would help.",
                   author: "lin.w", territory: "GBR", createdAt: ago(20),
                   reply: ReviewReply(text: "Thanks for telling us. We now offer 50% off for students; write to us and we will set it up.", date: ago(18), pending: false)),
            Review(storeId: "d6", platform: .googlePlay, projectId: lumenId, rating: 5,
                   body: "Найкращий застосунок для нотаток, яким я користувався. Дякую!",
                   author: "Олена", language: "uk_UA", createdAt: ago(26)),
            Review(storeId: "d7", platform: .appStore, projectId: ferryId, rating: 2, title: "Widget doesn't update",
                   body: "The departure widget shows yesterday's times until I open the app.",
                   author: "commuter88", territory: "CAN", createdAt: ago(4)),
            Review(storeId: "d8", platform: .appStore, projectId: ferryId, rating: 5, title: "Saves my mornings",
                   body: "Exactly what I needed for the island ferries. Offline mode works perfectly.",
                   author: "seabird", territory: "NZL", createdAt: ago(30),
                   reply: ReviewReply(text: "This made our day. Safe crossings!", date: ago(29), pending: false)),
            Review(storeId: "d9", platform: .appStore, projectId: ferryId, rating: 1, title: "Wrong timetable",
                   body: "Sunday schedule is wrong for the 7:40 boat. I missed it.",
                   author: "pt_r", territory: "PRT", createdAt: ago(40)),
            Review(storeId: "d10", platform: .googlePlay, projectId: atlasId, rating: 4,
                   body: "Lovely maps and very calm design. Please add hiking trails for Scotland.",
                   author: "Ewan", language: "en_GB", createdAt: ago(7)),
            Review(storeId: "d11", platform: .googlePlay, projectId: atlasId, rating: 3,
                   body: "Schöne App, aber die Offline-Karten brauchen zu viel Speicher.",
                   author: "Jonas", language: "de_DE", createdAt: ago(31))
        ]
    }
}

/// Small deterministic generator for stable demo history and reproducible tests.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
