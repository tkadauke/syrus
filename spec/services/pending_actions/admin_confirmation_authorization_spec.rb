require "rails_helper"

RSpec.describe "admin pending action confirmation authorization" do
  DIRECT_EXECUTE_ADMIN_ACTIONS = {
    "admin_cleanup_workspace" => { payload: { "workflow_id" => 123 }, reason: "delete stale workspace" },
    "admin_clear_github_cache" => { payload: {} },
    "admin_kill_process" => { payload: { "process_id" => 123 } },
    "admin_pause_polling" => { payload: {} },
    "admin_pause_runs" => { payload: {} },
    "admin_pause_user_scheduling" => { payload: ->(user) { { "user_id" => user.id } } },
    "admin_reap_stale_runs" => { payload: {} },
    "admin_refresh_installations" => { payload: {} },
    "admin_retry_step" => { payload: { "workflow_id" => 123, "step_slug" => "implement" }, reason: "retry failed step" },
    "admin_unpause_polling" => { payload: {} },
    "admin_unpause_runs" => { payload: {} },
    "admin_unpause_user_scheduling" => { payload: ->(user) { { "user_id" => user.id } } },
    "clear_provider_circuit" => {
      payload: ->(user) { { "provider" => "claude", "user_id" => user.id, "positive_evidence" => "manual verification" } },
      reason: "provider recovered"
    },
    "force_fail_job" => { payload: { "job_id" => 123 }, reason: "operator repair" },
    "manual_agentic_run" => {
      payload: { "job_id" => 123, "base" => "current_pr_branch", "instructions" => "Repair the branch.", "push" => false },
      reason: "operator repair"
    },
    "repair_provider_circuit_evidence" => {
      payload: { "evidence_type" => "run", "evidence_id" => 123, "repair_status" => "repaired" },
      reason: "evidence repaired"
    },
    "wake_landing_queue" => { payload: { "reason" => "landing queue looks stuck" }, reason: "landing queue looks stuck" },
    "wake_provider_admission" => { payload: { "provider" => "claude" }, reason: "provider recovered" }
  }.freeze

  before do
    allow(User).to receive(:chat_providers).and_return(%w[claude])
  end

  DIRECT_EXECUTE_ADMIN_ACTIONS.each do |action_key, attributes|
    it "re-checks admin status before executing #{action_key}" do
      admin = Factories.user(admin: true)
      chat_session = ChatSession.create!(user: admin)
      payload = attributes.fetch(:payload)
      payload = payload.call(admin) if payload.respond_to?(:call)
      action = chat_session.pending_actions.create!(
        action: action_key,
        payload: payload,
        reason: attributes[:reason],
        requested_by: "agent"
      )
      command_class = PendingActions.for(action_key)
      allow_any_instance_of(command_class).to receive(:execute).and_raise("executed #{action_key}")

      admin.update!(global_role: "user")

      expect { action.confirm!(user: admin) }.to raise_error(ArgumentError, /Admin access required/)
      expect(action.reload).to be_failed
      expect(action.execution_error).to include("Admin access required")
    end
  end
end
