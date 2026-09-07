require "rails_helper"

RSpec.describe AttentionItems::ActionExecutor do
  let(:admin) { Factories.user(admin: true) }

  def item_with_action(job:, action_key:, label: "Retry from the failed step", payload: { "job_id" => job.id })
    Factories.attention_item(
      repository: job.repository,
      job: job,
      actions: [ { "action_key" => action_key, "label" => label, "payload" => payload } ]
    )
  end

  it "runs the item's retry_job action and records an admin audit entry" do
    job = Factories.job_record
    Workflows::Initial.instantiate(job: job).update!(state: "succeeded")
    item = item_with_action(job: job, action_key: "retry_job")

    expect {
      result = described_class.call(attention_item: item, action_key: "retry_job", user: admin, reason: "escalated")
      expect(result).to be_success
    }.to change { job.workflows.where(trigger_kind: "retry").count }.by(1)

    audit = AdminAction.last
    expect(audit.user).to eq(admin)
    expect(audit.action).to eq("attention_item_retry_job")
    expect(audit.params["attention_item_id"]).to eq(item.id)
    expect(audit.params["reason"]).to eq("escalated")
  end

  it "runs on a Job the acting admin does not own" do
    other_user = Factories.user
    job = Factories.job_record(user: other_user)
    Workflows::Initial.instantiate(job: job).update!(state: "succeeded")
    item = item_with_action(job: job, action_key: "retry_job")

    expect(job.user).not_to eq(admin)

    result = described_class.call(attention_item: item, action_key: "retry_job", user: admin)

    expect(result).to be_success
    expect(job.workflows.where(trigger_kind: "retry").count).to eq(1)
  end

  it "runs the item's cancel_job action" do
    job = Factories.job
    item = item_with_action(job: job, action_key: "cancel_job", label: "Not actionable")

    result = described_class.call(attention_item: item, action_key: "cancel_job", user: admin)

    expect(result).to be_success
    expect(job.reload).to be_closed
    expect(job.closure_reason).to eq("cancelled")
  end

  it "fails when the action_key is not one of the item's own actions" do
    job = Factories.job
    item = item_with_action(job: job, action_key: "retry_job")

    result = described_class.call(attention_item: item, action_key: "cancel_job", user: admin)

    expect(result).not_to be_success
    expect(result.error).to match(/not one of this item's actions/)
  end

  it "fails validation instead of executing when the stored payload is incomplete" do
    job = Factories.job
    item = item_with_action(job: job, action_key: "retry_job", payload: {})

    result = described_class.call(attention_item: item, action_key: "retry_job", user: admin)

    expect(result).not_to be_success
    expect(result.error).to match(/job_id is required/)
    expect(job.workflows.where(trigger_kind: "retry")).to be_empty
  end
end
