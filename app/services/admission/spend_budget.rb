module Admission
  # A user's spend against their daily ceiling (workflow-engine-v3 C1).
  #
  # Syrus already *accounts* for spend -- `Run#cost_usd` and
  # `ChatSession#cumulative_cost_usd` feed the spending insights page -- but
  # nothing enforces it. A budget that is only ever reported is a budget in
  # name.
  #
  # Like the fairness rung, being over budget **defers**: the work waits for
  # the next day's budget rather than failing. A failed Job is a person's
  # problem; a deferred one is a queue's.
  class SpendBudget
    Result = Data.define(:over_budget, :spent_usd, :budget_usd, :resets_at) do
      def over_budget? = over_budget
      def unlimited? = budget_usd.to_i <= 0

      def to_h
        {
          "spent_usd" => spent_usd.round(4), "budget_usd" => budget_usd,
          "resets_at" => resets_at&.iso8601
        }.compact
      end
    end

    def self.for(...) = new(...).call

    def initialize(user:, now: Time.current, budget_usd: nil)
      @user = user
      @now = now
      @budget_usd = budget_usd || AppSetting.user_daily_spend_budget_usd
    end

    def call
      return unlimited_result if @budget_usd.to_i <= 0 || @user.nil?

      spent = run_spend + chat_spend

      Result.new(
        over_budget: spent >= @budget_usd,
        spent_usd: spent,
        budget_usd: @budget_usd,
        resets_at: @now.end_of_day
      )
    end

    private

    # The window is the calendar day in the instance's zone, which is what
    # "daily budget" means to the person who set it.
    def window = @now.beginning_of_day..@now.end_of_day

    def run_spend
      ::Run.where(user_id: @user.id, created_at: window).sum(:cost_usd).to_f
    end

    def chat_spend
      return 0.0 unless ChatSession.column_names.include?("cumulative_cost_usd")

      ChatSession.where(user_id: @user.id, updated_at: window).sum(:cumulative_cost_usd).to_f
    end

    def unlimited_result
      Result.new(over_budget: false, spent_usd: 0.0, budget_usd: @budget_usd.to_i, resets_at: nil)
    end
  end
end
