import SwiftUI
import WidgetKit

/// What the widget gallery shows: a made-up day, so each widget looks like itself there even when the real one is
/// empty (no stops near, nothing logged yet). Decoded the way the server's answers are.
@MainActor
enum WidgetSamples {
    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> Loaded<T>? {
        (try? JSONDecoder.api.decode(T.self, from: Data(json.utf8))).map { Loaded(value: $0, fresh: true) }
    }

    private static func at(_ minutes: Double) -> String { Wire.local(Date() + minutes * 60) }

    static let agents: [Agent] = decode(AgentList.self, """
    {"agents": [
      {"id": "aide", "name": "Aide", "color": "#34413F", "orchestrator": true},
      {"id": "secretary", "name": "Secretary", "color": "#3D7DB0"},
      {"id": "professor", "name": "Professor", "color": "#8F5A9C"},
      {"id": "coach", "name": "Coach", "color": "#2F9E6E"},
      {"id": "finance", "name": "Finance", "color": "#D9A340"}
    ]}
    """)?.value.agents ?? [.aide]

    static var today: Loaded<TodayResponse>? {
        decode(TodayResponse.self, """
        {"date": "\(Wire.dayString(Date()))",
         "events": [
           {"id": "e1", "title": "Macroeconomics", "calendar": "Timetable", "start": "\(at(-20))", "end": "\(at(70))",
            "location": "Aula 7, Campus Einaudi"},
           {"id": "e2", "title": "Lunch with Giulia", "calendar": "Personal", "start": "\(at(100))", "end": "\(at(160))",
            "location": "Porta Palazzo"},
           {"id": "e3", "title": "Gym", "calendar": "Health", "start": "\(at(300))", "end": "\(at(360))"}
         ],
         "reminders": [
           {"id": "r1", "title": "Pay rent", "due_at": "\(at(-1500))"},
           {"id": "r2", "title": "Sign up for the statistics exam", "due_at": "\(at(240))"},
           {"id": "r3", "title": "Buy milk"}
         ]}
        """)
    }

    static let food = decode(FoodDay.self, """
    {"date": "2026-10-26", "meals": [],
     "totals": {"calories": 1340, "protein_g": 72, "carbs_g": 160, "fat_g": 41},
     "goals": {"calories": 2200, "protein_g": 140, "carbs_g": 250, "fat_g": 70}}
    """)

    static let habits = decode(HabitList.self, """
    {"habits": [
      {"id": 1, "name": "Run", "cadence": {"type": "weekly", "per_week": 3}, "streak": 4, "done_today": true},
      {"id": 2, "name": "Read 20 pages", "cadence": {"type": "daily"}, "streak": 12, "done_today": false},
      {"id": 3, "name": "No phone in bed", "cadence": {"type": "daily"}, "streak": 0, "done_today": false},
      {"id": 4, "name": "Stretch", "cadence": {"type": "daily"}, "streak": 2, "done_today": true}
    ]}
    """)

    static let objectives = decode(ObjectivesOverview.self, """
    {"day": {"period": "day", "start": "2026-10-26", "end": "2026-10-26", "planned": true, "objectives": [
       {"id": "o1", "agent": "professor", "period": "day", "start": "2026-10-26", "end": "2026-10-26",
        "title": "Revise IS-LM", "measure": {"type": "notes"}, "progress": 1, "target": 2, "done": false, "status": "active"},
       {"id": "o2", "agent": "coach", "period": "day", "start": "2026-10-26", "end": "2026-10-26",
        "title": "Run 5 km", "measure": {"type": "habit"}, "progress": 1, "target": 1, "done": true, "status": "active"},
       {"id": "o3", "agent": "secretary", "period": "day", "start": "2026-10-26", "end": "2026-10-26",
        "title": "Answer the landlord", "progress": 0, "target": 1, "done": false, "status": "active"},
       {"id": "o4", "agent": "coach", "period": "day", "start": "2026-10-26", "end": "2026-10-26",
        "title": "140 g of protein", "measure": {"type": "food"}, "progress": 72, "target": 140, "done": false,
        "status": "active"}
     ]},
     "week": {"period": "week", "start": "2026-10-26", "end": "2026-11-01", "planned": true, "objectives": []},
     "month": {"period": "month", "start": "2026-10-01", "end": "2026-10-31", "planned": true, "objectives": []}}
    """)

    static var nearby: Loaded<NearbyBoards>? {
        func arrivals(_ minutes: [Double], live: Bool = true) -> String {
            minutes.map { #"{"at": "\#(at($0))", "scheduled": "\#(at($0))", "live": \#(live), "delay": \#(live ? "60" : "null")}"# }
                .joined(separator: ",")
        }
        return decode(NearbyBoards.self, """
        {"fix_at": "\(at(-2))", "boards": [
          {"id": "b1", "stop": {"id": "s1", "code": "470", "name": "Porta Nuova"}, "at": "\(at(0))",
           "distance": 220, "walk": 180, "lines": [
             {"line": "4", "vehicle": "Tram", "towards": "Falchera", "arrivals": [\(arrivals([5, 13, 21]))]},
             {"line": "68", "vehicle": "Bus", "towards": "Corso Casale", "arrivals": [\(arrivals([9, 24]))]}
           ]},
          {"id": "b2", "stop": {"id": "s2", "code": "469", "name": "Porta Nuova"}, "at": "\(at(0))",
           "distance": 240, "walk": 200, "lines": [
             {"line": "4", "vehicle": "Tram", "towards": "Mirafiori Sud", "arrivals": [\(arrivals([7, 15]))]},
             {"line": "15", "vehicle": "Tram", "towards": "Sassi", "arrivals": [\(arrivals([11, 23], live: false))]}
           ]},
          {"id": "b3", "stop": {"id": "s3", "code": "471", "name": "Via Sacchi"}, "at": "\(at(0))",
           "distance": 400, "walk": 330, "lines": [
             {"line": "9", "vehicle": "Tram", "towards": "Stadio Olimpico", "arrivals": [\(arrivals([8, 16]))]},
             {"line": "33", "vehicle": "Bus", "towards": "Lingotto", "arrivals": [\(arrivals([14], live: false))]}
           ]}
        ]}
        """)
    }
}

#if DEBUG
#Preview("Today", as: .systemSmall) { TodayWidget() } timeline: {
    TodayEntry(date: .now, today: WidgetSamples.today)
}
#Preview("Today", as: .systemMedium) { TodayWidget() } timeline: {
    TodayEntry(date: .now, today: WidgetSamples.today)
}
#Preview("Today", as: .accessoryRectangular) { TodayWidget() } timeline: {
    TodayEntry(date: .now, today: WidgetSamples.today)
}
#Preview("Health", as: .systemSmall) { HealthWidget() } timeline: {
    HealthEntry(date: .now, food: WidgetSamples.food, habits: WidgetSamples.habits, agents: WidgetSamples.agents)
}
#Preview("Health", as: .systemMedium) { HealthWidget() } timeline: {
    HealthEntry(date: .now, food: WidgetSamples.food, habits: WidgetSamples.habits, agents: WidgetSamples.agents)
}
#Preview("Objectives", as: .systemSmall) { ObjectivesWidget() } timeline: {
    ObjectivesEntry(date: .now, overview: WidgetSamples.objectives, agents: WidgetSamples.agents)
}
#Preview("Objectives", as: .systemMedium) { ObjectivesWidget() } timeline: {
    ObjectivesEntry(date: .now, overview: WidgetSamples.objectives, agents: WidgetSamples.agents)
}
#Preview("Team", as: .systemSmall) { TeamWidget() } timeline: {
    TeamEntry(date: .now, agents: WidgetSamples.agents)
}
#Preview("Team", as: .systemMedium) { TeamWidget() } timeline: {
    TeamEntry(date: .now, agents: WidgetSamples.agents)
}
#Preview("Departures", as: .systemMedium) { DeparturesWidget() } timeline: {
    DeparturesEntry(date: .now, nearby: WidgetSamples.nearby)
}
#Preview("Departures", as: .systemLarge) { DeparturesWidget() } timeline: {
    DeparturesEntry(date: .now, nearby: WidgetSamples.nearby)
}
#endif
