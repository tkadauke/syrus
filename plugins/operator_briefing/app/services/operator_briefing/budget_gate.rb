module OperatorBriefing
  class BudgetGate
    Result = Data.define(:skip, :reason)

    def self.evaluate(settings)
      return Result.new(skip: false, reason: nil) unless settings.budget_check_enabled?

      # Spending Insights records actual costs, but Syrus does not currently
      # expose a remaining-budget allowance to compare against. Keep this best
      # effort and fail open until that budget primitive exists.
      Result.new(skip: false, reason: "no_budget_allowance_available")
    end
  end
end
