require "rails_helper"

RSpec.describe "API: provider routing hold release", type: :request do
  let(:admin) { Factories.user(admin: true) }
  let(:job) { Factories.job(user: admin) }
  let(:workflow) { job.workflows.first }
  let(:rule) do
    ProviderRoutingRule.create!(
      scope_type: "job", scope_id: job.id, task_key: "initial", candidates: [],
      action: { type: "hold", reason: "Approval required" }
    )
  end
  let!(:hold) do
    ProviderRoutingHold.create!(
      workflow: workflow,
      provider_routing_rule: rule,
      resumption_mode: "manual",
      reason: "Approval required",
      condition_evidence: { "matched" => true },
      matched_scope: { "source_scope" => "job", "source_id" => job.id }
    )
  end

  it "requires an admin" do
    sign_in_as(Factories.user(admin: false))

    post "/api/v1/app/admin/provider_routing_holds/#{hold.id}/release", params: { reason: "Approved" }

    expect(response).to have_http_status(:forbidden)
    expect(hold.reload).to be_active
  end

  it "records an audited exceptional override and wakes admission" do
    sign_in_as(admin)

    expect {
      post "/api/v1/app/admin/provider_routing_holds/#{hold.id}/release",
        params: { reason: "Provider capacity verified", override: true }
    }.to have_enqueued_job(WorkflowPhaseAdmissionJob).with(workflow.id)

    expect(response).to have_http_status(:ok)
    expect(hold.reload).to have_attributes(
      status: "overridden",
      release_kind: "override",
      release_reason: "Provider capacity verified",
      released_by_user: admin
    )
  end
end
