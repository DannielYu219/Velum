//
//  BudgetGuard.swift
//  Velum
//
//  照抄 Visor BudgetGuard：金融级预算熔断（会话/日/月三段）
//  用户需求：financial-grade security，防止 AI 模型意外消耗
//

import Foundation
import Combine
import os.log

/// 预算熔断（金融级安全：会话/日/月三段）
@MainActor
final class BudgetGuard: ObservableObject {

    /// 全局单例：所有页面共享同一实例，状态自动同步
    static let shared = BudgetGuard()

    enum Period: String, CaseIterable, Sendable {
        case session
        case daily
        case monthly
    }

    struct Limit: Sendable, Equatable, Codable {
        var sessionUSD: Double = 5.0
        var dailyUSD: Double = 20.0
        var monthlyUSD: Double = 200.0
    }

    @Published private(set) var limit: Limit
    @Published private(set) var sessionSpent: Double = 0
    @Published private(set) var dailySpent: Double = 0
    @Published private(set) var monthlySpent: Double = 0

    @Published private(set) var triggeredPeriod: Period?
    private let logger = Logger(subsystem: "com.lyrastudio.Velum", category: "BudgetGuard")

    private static let limitKey = "agent.budgetLimit"
    private static let dailySpentKey = "agent.dailySpent"
    private static let monthlySpentKey = "agent.monthlySpent"
    private static let dailyDateKey = "agent.dailyDate"
    private static let monthlyDateKey = "agent.monthlyDate"

    init(limit: Limit? = nil) {
        if let saved = Self.loadLimit(), limit == nil {
            self.limit = saved
        } else {
            self.limit = limit ?? Limit()
            Self.saveLimit(self.limit)
        }
        Self.loadSpent(into: self)
    }

    /// 检查并增加本次预估费用
    /// - Returns: 允许时返回 true；超限时返回 false 并设置 triggeredPeriod
    @discardableResult
    func checkAndCharge(estimatedUSD: Double) -> Bool {
        if triggeredPeriod != nil { return false }
        if sessionSpent + estimatedUSD > limit.sessionUSD {
            triggeredPeriod = .session
            logger.error("Budget triggered: session")
            return false
        }
        if dailySpent + estimatedUSD > limit.dailyUSD {
            triggeredPeriod = .daily
            logger.error("Budget triggered: daily")
            return false
        }
        if monthlySpent + estimatedUSD > limit.monthlyUSD {
            triggeredPeriod = .monthly
            logger.error("Budget triggered: monthly")
            return false
        }
        // 预扣
        sessionSpent += estimatedUSD
        dailySpent += estimatedUSD
        monthlySpent += estimatedUSD
        Self.saveSpent(self)
        return true
    }

    /// 实际结算（流式完成后校正差额）
    func settle(actualUSD: Double, estimatedUSD: Double) {
        let diff = actualUSD - estimatedUSD
        if abs(diff) > 0.0001 {
            sessionSpent += diff
            dailySpent += diff
            monthlySpent += diff
            Self.saveSpent(self)
        }
    }

    /// 重置会话计数（新会话开始时）
    func resetSession() {
        sessionSpent = 0
        if triggeredPeriod == .session { triggeredPeriod = nil }
    }

    /// 用户更新预算
    func update(limit: Limit) {
        self.limit = limit
        Self.saveLimit(limit)
        if triggeredPeriod != nil, !isAnyExceeded() {
            triggeredPeriod = nil
        }
    }

    /// 警告阈值（80%）查询
    func isWarning(period: Period) -> Bool {
        switch period {
        case .session:
            return limit.sessionUSD > 0 && sessionSpent / limit.sessionUSD >= 0.8
        case .daily:
            return limit.dailyUSD > 0 && dailySpent / limit.dailyUSD >= 0.8
        case .monthly:
            return limit.monthlyUSD > 0 && monthlySpent / limit.monthlyUSD >= 0.8
        }
    }

    private func isAnyExceeded() -> Bool {
        sessionSpent > limit.sessionUSD
            || dailySpent > limit.dailyUSD
            || monthlySpent > limit.monthlyUSD
    }

    // MARK: - 持久化

    private static func loadLimit() -> Limit? {
        guard let data = UserDefaults.standard.data(forKey: limitKey) else { return nil }
        return try? JSONDecoder().decode(Limit.self, from: data)
    }

    private static func saveLimit(_ limit: Limit) {
        if let data = try? JSONEncoder().encode(limit) {
            UserDefaults.standard.set(data, forKey: limitKey)
        }
    }

    private static func loadSpent(into guard_: BudgetGuard) {
        let now = Date()
        let cal = Calendar.current
        let todayKey = cal.startOfDay(for: now).timeIntervalSince1970
        let monthKey = cal.dateComponents([.year, .month], from: now)

        // 检查 daily
        if let savedDailyDate = UserDefaults.standard.object(forKey: dailyDateKey) as? TimeInterval,
           cal.isDateInToday(Date(timeIntervalSince1970: savedDailyDate)) {
            guard_.dailySpent = UserDefaults.standard.double(forKey: dailySpentKey)
        } else {
            guard_.dailySpent = 0
            UserDefaults.standard.set(todayKey, forKey: dailyDateKey)
            UserDefaults.standard.set(0.0, forKey: dailySpentKey)
        }

        // 检查 monthly
        if let savedMonthlyDate = UserDefaults.standard.object(forKey: monthlyDateKey) as? TimeInterval {
            let savedDate = Date(timeIntervalSince1970: savedMonthlyDate)
            let savedComps = cal.dateComponents([.year, .month], from: savedDate)
            if savedComps.year == monthKey.year && savedComps.month == monthKey.month {
                guard_.monthlySpent = UserDefaults.standard.double(forKey: monthlySpentKey)
            } else {
                guard_.monthlySpent = 0
                UserDefaults.standard.set(now.timeIntervalSince1970, forKey: monthlyDateKey)
                UserDefaults.standard.set(0.0, forKey: monthlySpentKey)
            }
        } else {
            guard_.monthlySpent = 0
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: monthlyDateKey)
            UserDefaults.standard.set(0.0, forKey: monthlySpentKey)
        }
    }

    private static func saveSpent(_ guard_: BudgetGuard) {
        UserDefaults.standard.set(guard_.dailySpent, forKey: dailySpentKey)
        UserDefaults.standard.set(guard_.monthlySpent, forKey: monthlySpentKey)
    }
}
