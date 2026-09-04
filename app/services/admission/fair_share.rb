module Admission
  # A user's share of the instance's agent capacity (workflow-engine-v3 C1).
  #
  # `max_concurrent_agent_runs` is one global integer and `WorkflowAdmissionBudget`
  # scopes to a repository, never to a user. One user's large Epic can therefore
  # occupy every slot and starve everyone else -- authorization is done, but
  # resource isolation does not exist.
  #
  # The share is computed against the users who are *actually contending right
  # now*, not against every account: an instance with one active user should
  # let that user use the whole cap. It only bites when someone else is waiting.
  #
  # The plan's guardrail is absolute and is enforced by the caller: an
  # over-share user's work **defers**. It never fails. A starvation guard that
  # fails work converts a queueing problem into an attention problem, which is
  # the opposite of what this plan is for.
  class FairShare
    Result = Data.define(:over_share, :active, :share, :contenders, :limit) do
      def over_share? = over_share
      def unlimited? = limit.to_i <= 0

      def to_h
        { "active" => active, "share" => share, "contenders" => contenders, "limit" => limit }
      end
    end

    def self.for(...) = new(...).call

    def initialize(user:, excluding_run_id: nil, limit: nil)
      @user = user
      @excluding_run_id = excluding_run_id
      @limit = limit || AppSetting.max_concurrent_agent_runs
    end

    def call
      return unlimited_result if @limit.to_i <= 0 || @user.nil?

      counts = active_runs_by_user
      contenders = [ counts.keys.size, 1 ].max
      # Always at least one: a share that rounds to zero would defer work
      # forever rather than slowly.
      share = [ @limit / contenders, 1 ].max
      active = counts.fetch(@user.id, 0)

      Result.new(
        over_share: active >= share && contenders > 1,
        active: active,
        share: share,
        contenders: contenders,
        limit: @limit
      )
    end

    private

    # Only users with an agent Run in flight count as contending. A user with
    # queued work but nothing running is not yet competing for a slot.
    def active_runs_by_user
      scope = ::Run.running_agent_runs
      scope = scope.where.not(id: @excluding_run_id) if @excluding_run_id

      scope.group(:user_id).count
    end

    def unlimited_result
      Result.new(over_share: false, active: 0, share: 0, contenders: 0, limit: @limit)
    end
  end
end
