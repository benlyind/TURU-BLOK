import Foundation

struct LockConfig {
    let startHour: Int
    let endHour: Int
    let timezone: TimeZone

    static func current() -> LockConfig {
        LockConfig(
            startHour: 23,
            endHour: 7,
            timezone: TimeZone(identifier: "Asia/Jakarta") ?? .current
        )
    }

    func isWithinLockWindow(_ date: Date) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        let hour = cal.component(.hour, from: date)
        if startHour < endHour {
            return hour >= startHour && hour < endHour
        } else {
            return hour >= startHour || hour < endHour
        }
    }

    func nextEndDate(from date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        var comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
        comps.hour = endHour
        comps.minute = 0
        comps.second = 0

        guard var end = cal.date(from: comps) else { return date }
        if startHour > endHour {
            let currentHour = cal.component(.hour, from: date)
            if currentHour >= startHour {
                end = cal.date(byAdding: .day, value: 1, to: end) ?? end
            }
        } else if end <= date {
            end = cal.date(byAdding: .day, value: 1, to: end) ?? end
        }
        return end
    }

    func nextStartDate(from date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        var comps = cal.dateComponents([.year, .month, .day], from: date)
        comps.hour = startHour
        comps.minute = 0
        comps.second = 0
        guard var start = cal.date(from: comps) else { return date }
        if start <= date {
            start = cal.date(byAdding: .day, value: 1, to: start) ?? start
        }
        return start
    }
}
