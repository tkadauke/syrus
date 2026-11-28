module Coworkers
  class JobAutonomyComparison
    def self.call(...) = new(...).call

    def initialize(coworker:)
      @coworker = coworker
    end

    def call
      synchronize!
      rows = @coworker.job_autonomy_shadow_decisions.order(created_at: :desc)
      {
        "actions" => Coworkers::JobAutonomy::CAPABILITIES.keys.index_with { |action| summary(rows.where(action:)) },
        "disagreements" => rows.where.not(operator_decision: nil).select { |row| !row.agreement? }.first(25).map { |row| serialize(row) }
      }
    end

    private

    def synchronize!
      @coworker.job_autonomy_shadow_decisions.where(operator_decision: nil).includes(:chat_pending_action).find_each do |row|
        pending = row.chat_pending_action
        decision = "act" if pending.state.in?(%w[confirming confirmed completed])
        decision = "abstain" if pending.state.in?(%w[rejected cancelled dismissed])
        next unless decision

        job_id = row.job_id || (pending.result_id if pending.result_type == "Job")
        row.update!(operator_decision: decision, operator_decided_at: pending.confirmed_at || pending.rejected_at || pending.updated_at,
          job_id: job_id)
      end
    end

    def summary(scope)
      decided = scope.where.not(operator_decision: nil).to_a
      agreed = decided.count(&:agreement?)
      { "shadow_decisions" => scope.count, "paired" => decided.size, "agreed" => agreed,
        "disagreed" => decided.size - agreed, "agreement_rate" => decided.empty? ? nil : (agreed.to_f / decided.size) }
    end

    def serialize(row)
      { "id" => row.id, "action" => row.action, "job_id" => row.job_id,
        "predicted_decision" => row.predicted_decision, "operator_decision" => row.operator_decision,
        "evidence" => row.evidence, "guardrail_outcomes" => row.guardrail_outcomes,
        "created_at" => row.created_at.iso8601 }
    end
  end
end
