require "rails_helper"

RSpec.describe PendingActions::DetachJob do
  let(:admin) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: admin, default_branch: "main") }
  let(:chat_session) { ChatSession.create!(user: admin, repository: repository) }

  def detach_action(job)
    chat_session.pending_actions.create!(
      action: "detach_job",
      payload: {
        "job_id" => job.id,
        "destination_base" => "main",
        "plan" => {
          "inferred_parent_job_id" => nil, "former_parent_head" => "b" * 40,
          "owned_patch_base_sha" => "c" * 40, "current_branch_head" => "a" * 40
        }
      },
      reason: "Repair an accidental stack parent.",
      requested_by: "agent"
    )
  end

  # Detach force-pushes the Job's branch and moves its PR base. Work holding
  # the Job's WorkUnit lock (a feedback or auto-merge Workflow) would push
  # onto, or merge, the branch it rewrote and fail on the lease, losing the
  # work instead of the detach being refused up front (F148).
  it "refuses while the Job has active work" do
    job = Factories.job(user: admin, repository: repository, agent_provider: "claude")
    job.update_columns(pr_number: 4242, branch_name: "syrus/child")
    expect(job.active_runtime_workflows).to be_present
    allow(JobDetachRepair).to receive(:call)

    expect { detach_action(job).confirm!(user: admin) }.to raise_error(ArgumentError, /active work/)

    expect(JobDetachRepair).not_to have_received(:call)
  end
end
