require "rails_helper"

RSpec.describe "Mcp::Tools ref-movement action tools" do
  let(:user) { Factories.user }
  let(:canonical) { Factories.repository(user: user, default_branch: "main") }
  let(:fork_repo) { Factories.repository(user: user, default_branch: "main", upstream_repository: canonical) }
  let(:chat_session) { ChatSession.create!(user: user, repository: fork_repo) }
  let(:send_config) { SyrusYml::DeliveryRefMovementAction.new(name: "send_job_upstream", enabled: true, source: nil, target: nil, mode: "manual_pr", grade_phases: []) }

  def chat_context = { chat_session: chat_session }

  def payload(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)
  end

  before do
    allow(StepDispatcher).to receive(:start_workflow)
  end

  describe Mcp::Tools::ListRefMovementActionsTool do
    it "lists nothing when no ref_movement_actions are configured" do
      response = described_class.call(server_context: chat_context)

      expect(response).not_to be_error
      expect(payload(response)[:ref_movement_actions]).to eq([])
    end

    it "lists a configured action's availability" do
      allow_any_instance_of(DeliveryPolicy).to receive(:ref_movement_actions).and_return({ "send_job_upstream" => send_config })
      allow(RefMovementActions::Base).to receive(:for).with("send_job_upstream").and_return(
        instance_double(RefMovementActions::SendJobUpstream, available?: [ false, "job is required for send_job_upstream" ])
      )

      body = payload(described_class.call(server_context: chat_context))
      expect(body[:ref_movement_actions]).to contain_exactly(
        a_hash_including(name: "send_job_upstream", enabled: true, mode: "manual_pr", available: false, blocked_reason: "job is required for send_job_upstream")
      )
    end
  end

  describe Mcp::Tools::DispatchRefMovementActionTool do
    it "requires job_id for send_job_upstream" do
      response = described_class.call(action: "send_job_upstream", server_context: chat_context)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("job_id is required")
    end

    it "creates a RefMovementAction row and reports the blocked reason when unsupported" do
      response = described_class.call(action: "totally_unsupported", server_context: chat_context)

      expect(response).not_to be_error
      body = payload(response)
      expect(body[:state]).to eq("blocked")
      expect(body[:blocked_reason]).to include("unsupported ref-movement action")
      expect(RefMovementAction.find(body[:ref_movement_action_id])).to be_blocked
    end

    it "dispatches send_job_upstream for an eligible job and returns the audit record" do
      allow_any_instance_of(DeliveryPolicy).to receive(:ref_movement_action_config).with("send_job_upstream").and_return(send_config)
      allow_any_instance_of(DeliveryPolicy).to receive(:upstream_export_enabled?).and_return(true)
      allow_any_instance_of(DeliveryPolicy).to receive(:upstream_export_target_branch).and_return("develop")
      job = Factories.job_record(user: user, repository: fork_repo, state: "approved", branch_name: "syrus/issue-1")

      response = described_class.call(action: "send_job_upstream", job_id: job.id, server_context: chat_context)

      expect(response).not_to be_error
      body = payload(response)
      expect(body[:state]).to eq("dispatched")
      expect(body[:job_id]).to eq(job.id)
      expect(body[:target_repository]).to eq(canonical.slug)
      expect(body[:target_inferred]).to be(true)
    end

    it "rejects a job_id belonging to a different repository" do
      other_job = Factories.job_record(user: user, repository: Factories.repository(user: user))

      response = described_class.call(action: "send_job_upstream", job_id: other_job.id, server_context: chat_context)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("different repository")
    end
  end

  describe Mcp::Tools::ReadRefMovementStatusTool do
    it "returns an error for an unknown id" do
      response = described_class.call(ref_movement_action_id: 0, server_context: chat_context)

      expect(response).to be_error
    end

    it "reports state, refs, job, and workflow for a dispatched record" do
      record = RefMovementAction.create!(
        repository: fork_repo, requested_by_user: user, action_name: "submit_branch_upstream",
        state: "dispatched", source_kind: "branch", source_ref: "develop",
        target_kind: "upstream_intake", target_ref: "main", target_repository: canonical,
        target_inferred: true, mode: "manual_pr"
      )

      response = described_class.call(ref_movement_action_id: record.id, server_context: chat_context)

      expect(response).not_to be_error
      body = payload(response)
      expect(body[:action_name]).to eq("submit_branch_upstream")
      expect(body[:state]).to eq("dispatched")
      expect(body[:target_repository]).to eq(canonical.slug)
      expect(body[:requested_by]).to eq(user.email_address)
    end

    it "includes the PR link when the associated job recorded one" do
      job = Factories.job_record(user: user, repository: fork_repo, branch_name: "develop")
      JobPrLink.record!(job: job, role: JobPrLink::ROLE_UPSTREAM_EXPORT, pr_number: 77, target_repository_id: canonical.id, target_ref: "main", metadata: { "pr_state" => "open" })
      record = RefMovementAction.create!(
        repository: fork_repo, requested_by_user: user, action_name: "send_job_upstream",
        state: "dispatched", job: job, mode: "manual_pr"
      )

      body = payload(described_class.call(ref_movement_action_id: record.id, server_context: chat_context))

      expect(body.dig(:pr_link, :pr_number)).to eq(77)
      expect(body.dig(:pr_link, :pr_state)).to eq("open")
    end
  end
end
