require "rails_helper"

RSpec.describe PlannedExecutionRequirement do
  def loaded_config(yaml)
    RepoDefaultBranchSyrusYml::Result.new(
      config: SyrusYml.new(yaml).parse,
      source: ".syrus.yml",
      note: nil,
      outcome: :loaded
    )
  end

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

  it "plans new jobs from root project capabilities before workflow launch" do
    user = Factories.user
    repository = Factories.repository(user: user)
    job = Factories.job_record(user: user, repository: repository)
    allow(RepoDefaultBranchSyrusYml).to receive(:for_job).with(job).and_return(
      loaded_config(<<~YAML)
        project:
          label: iOS App
          capabilities:
            os: macos
            toolchains: [xcode]
      YAML
    )

    requirement = job.ensure_planned_execution_requirements!

    expect(requirement.to_h).to eq(
      "project_label" => "iOS App",
      "target_label" => "//:repo",
      "capabilities" => { "os" => [ "macos" ], "toolchains" => [ "xcode" ] },
      "source" => "inferred"
    )
    expect(job.reload.planned_execution_json).to eq(requirement.to_h)
  end
end
