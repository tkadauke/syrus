require "rails_helper"

RSpec.describe Workflows::Filter do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(repository: repo, issue_number: 1) }

  def workflow(**attrs)
    Workflow.create!({
      job: job,
      trigger_kind: "initial",
      agent_provider: "claude"
    }.merge(attrs))
  end

  it "matches the Epics::Filter public surface" do
    filter = described_class.from_tree({ "field" => "state", "op" => "is", "value" => "queued" }, user: user)

    expect(filter).to respond_to(:apply, :active?, :pinned?, :to_h, :to_query_param)
    expect(filter).to be_active
    expect(filter.pinned?).to be(false)
  end

  it "builds a filter from legacy URL params" do
    match = workflow(state: "running", trigger_kind: "retry")
    workflow(state: "queued", trigger_kind: "initial")

    filter = described_class.from_params({ state: "running", trigger_kind: "retry", job_id: job.id }, user: user)

    expect(filter.apply(Workflow.all)).to contain_exactly(match)
  end

  it "ANDs smart folder, q param, and legacy params together" do
    match = workflow(state: "running", trigger_kind: "manual", agent_provider: "codex")
    workflow(state: "running", trigger_kind: "manual", agent_provider: "claude")

    q = Filters::QueryParam.encode("field" => "trigger_kind", "op" => "is", "value" => "manual")
    folder = Struct.new(:filter).new({ "field" => "agent_provider", "op" => "is", "value" => "codex" })

    filter = described_class.from_params({ "q" => q, "state" => "running" }, smart_folder: folder, user: user)

    expect(filter.apply(Workflow.all)).to contain_exactly(match)
  end
end
