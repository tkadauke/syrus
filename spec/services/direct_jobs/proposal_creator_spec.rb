require "rails_helper"

RSpec.describe DirectJobs::ProposalCreator do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:epic) { Factories.epic(user: user, repository: repository) }

  def create_job(title:, **overrides)
    described_class.new(user: user).call(
      repository: repository,
      prompt_text: "Do the thing.",
      title: title,
      priority: "medium",
      agent_provider: nil,
      model: nil,
      effort_level: nil,
      epic: epic,
      planned_execution_attrs: { planned_execution_capabilities: { "os" => [ "linux" ] } },
      **overrides
    )
  end

  # ProposeJobTool refuses a Job aimed at a non-empty Epic unless it names one
  # of that Epic's Jobs, because Epics execute as one stacked branch. An agent
  # passes the tail explicitly; this path has no dependency control in its form
  # at all, so adding a second Job to an Epic from the UI was impossible -- it
  # failed with the tool's agent-facing message and no field to satisfy it.
  it "chains a Job created into a non-empty Epic onto that Epic's tail" do
    first = create_job(title: "First child")
    expect(first).to be_success, first.error.to_s

    second = create_job(title: "Second child")

    expect(second).to be_success, second.error.to_s
    expect(second.job.dependencies.map(&:depends_on_job_id)).to eq([ first.job.id ])
  end

  it "chains each later Job onto the newest tail rather than the Epic's head" do
    first = create_job(title: "First child")
    second = create_job(title: "Second child")

    third = create_job(title: "Third child")

    expect(third).to be_success, third.error.to_s
    expect(third.job.dependencies.map(&:depends_on_job_id)).to eq([ second.job.id ])
    expect(first.job.reload.dependencies).to be_empty
  end

  it "leaves an explicitly requested dependency alone" do
    first = create_job(title: "First child")
    second = create_job(title: "Second child")

    third = create_job(title: "Third child", depends_on_job_ids: [ second.job.id ])

    expect(third).to be_success, third.error.to_s
    expect(third.job.dependencies.map(&:depends_on_job_id)).to eq([ second.job.id ])
    expect(first.job.reload.dependencies).to be_empty
  end

  it "needs no dependency for the first Job in an empty Epic" do
    result = create_job(title: "Only child")

    expect(result).to be_success, result.error.to_s
    expect(result.job.dependencies).to be_empty
  end
end
