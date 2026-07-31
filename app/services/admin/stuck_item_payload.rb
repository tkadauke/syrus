module Admin
  class StuckItemPayload
    def self.serialize(...) = new(...).serialize

    def initialize(item:, include_actions: true)
      @item = item
      @include_actions = include_actions
    end

    def serialize
      {
        kind: item.kind.to_s,
        severity: item.severity.to_s,
        reconciler_severity: item.reconciler_severity,
        attention_state: item.attention_state,
        detail: item.detail,
        age_label: item.age_label,
        run_id: item.run&.id,
        workflow_id: item.workflow&.id,
        workflow_slug: item.workflow&.slug,
        workflow_path: item.workflow ? App::WorkflowNavigation.path(item.workflow) : nil,
        workflow_trigger_kind: item.workflow&.trigger_kind,
        step_kind: step_kind,
        job_id: item.job&.id,
        job_state: item.job&.state,
        job_path: item.job ? "/jobs/#{item.job.id}" : nil,
        force_fail_path: include_actions ? force_fail_path_for(item.job) : nil,
        has_transcript: item.run&.claude_session.present?,
        issue: item.issue&.as_json,
        repair_plan: item.repair_plan&.as_json,
        repair_execution: item.repair_execution&.as_json
      }
    end

    private

    attr_reader :item, :include_actions

    def step_kind
      item.run&.step&.kind || item.workflow&.current_step&.kind
    end

    def force_fail_path_for(job)
      return unless job&.state.in?(%w[running queued implemented approved landing])
      return unless job.may_force_fail?

      "/api/v1/app/jobs/#{job.id}/force_fail"
    end
  end
end
