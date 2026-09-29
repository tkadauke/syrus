require "rails_helper"

RSpec.describe PlannedExecutionRequirement do
  it "defaults old rows to ordinary Linux execution" do
    requirement = described_class.new

    expect(requirement.to_h).to eq(
      "project_label" => nil,
      "target_label" => nil,
      "capabilities" => { "os" => [ "linux" ] },
      "source" => "defaulted"
    )
  end

  it "normalizes explicit capability dimensions" do
    requirement = described_class.new(
      project_label: " iOS ",
      target_label: "//app:grade/tests",
      capabilities: {
        "os" => "macOS",
        "arch" => [ "ARM64" ],
        "toolchains" => [ "Xcode", "xcode", "" ],
        "features" => "simulator"
      },
      source: "explicit"
    )

    expect(requirement.to_h).to eq(
      "project_label" => "iOS",
      "target_label" => "//app:grade/tests",
      "capabilities" => {
        "os" => [ "macos" ],
        "arch" => [ "arm64" ],
        "toolchains" => [ "xcode" ],
        "features" => [ "simulator" ]
      },
      "source" => "explicit"
    )
  end

  it "defaults new jobs and manually created workflows" do
    user = Factories.user
    repository = Factories.repository(user: user)
    job = Factories.job_record(user: user, repository: repository)
    workflow = Workflow.create!(job: job, user: user, trigger_kind: "manual", agent_provider: job.agent_provider)

    expect(job.planned_execution_json).to eq(
      "project_label" => nil,
      "target_label" => nil,
      "capabilities" => { "os" => [ "linux" ] },
      "source" => "defaulted"
    )
    expect(workflow.planned_execution_json).to eq(job.planned_execution_json)
  end
end
