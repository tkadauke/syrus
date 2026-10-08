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

  it "rejects non-hash capability values with a controlled error" do
    expect {
      described_class.new(capabilities: "macos")
    }.to raise_error(ArgumentError, "planned execution capabilities must be a Hash or TargetGraph::ExecutionCapabilities")
  end

  it "normalizes explicit execution capabilities" do
    requirement = described_class.new(
      project_label: " iOS ",
      target_label: "//app:grade/tests",
      capabilities: { "os" => "macOS", "arch" => "ARM64", "toolchain" => "Xcode", "runtime" => "iOS_Simulator" },
      source: "explicit"
    )

    expect(requirement.to_h).to eq(
      "project_label" => "iOS",
      "target_label" => "//app:grade/tests",
      "capabilities" => {
        "os" => [ "macos" ],
        "arch" => [ "arm64" ],
        "toolchain" => [ "xcode" ],
        "runtime" => [ "ios_simulator" ]
      },
      "source" => "explicit"
    )
  end

  it "rejects unsupported capability dimensions and OS values" do
    expect {
      described_class.new(capabilities: { "os" => [ "linux" ], "feature" => [ "docker" ] })
    }.to raise_error(ArgumentError, /unsupported keys feature/)

    expect {
      described_class.new(capabilities: { "os" => [ "windows" ] })
    }.to raise_error(ArgumentError, /os: values must be one of linux, macos/)
  end

  it "prevents unsupported capability labels from being persisted on Jobs" do
    user = Factories.user
    repository = Factories.repository(user: user)
    job = Job.new(
      user: user,
      repository: repository,
      issue_number: 42,
      issue_title: "Fix Rails and Node install",
      issue_body: "Backend work should not request free-form placement labels.",
      planned_execution_capabilities: { "os" => [ "linux" ], "feature" => [ "docker" ] },
      planned_execution_source: "prompt"
    )

    expect(job).not_to be_valid
    expect(job.errors[:planned_execution_capabilities].join).to include("unsupported keys feature")
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

  it "defaults blank persisted capability rows to ordinary Linux execution" do
    user = Factories.user
    repository = Factories.repository(user: user)
    job = Factories.job_record(user: user, repository: repository)
    job.update_columns(planned_execution_capabilities: nil, planned_execution_source: nil)

    expect(job.reload.planned_execution_json).to eq(
      "project_label" => nil,
      "target_label" => nil,
      "capabilities" => { "os" => [ "linux" ] },
      "source" => "defaulted"
    )
  end

  it "rejects malformed persisted capability values on planned execution records" do
    user = Factories.user
    repository = Factories.repository(user: user)
    job = Factories.job_record(user: user, repository: repository)
    chat = ChatSession.create!(user: user, repository: repository)

    expect(Job.new(user: user, repository: repository, issue_number: 42, planned_execution_capabilities: "macos")).not_to be_valid
    expect(Workflow.new(job: job, user: user, trigger_kind: "manual", planned_execution_capabilities: "macos")).not_to be_valid
    expect(ChatProposal.new(chat_session: chat, slug: "bad-capabilities", title: "Bad capabilities", body: "Body.", planned_execution_capabilities: "macos")).not_to be_valid
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
      YAML
    )

    requirement = job.ensure_planned_execution_requirements!

    expect(requirement.to_h).to eq(
      "project_label" => "iOS App",
      "target_label" => "//:repo",
      "capabilities" => { "os" => [ "macos" ] },
      "source" => "inferred"
    )
    expect(job.reload.planned_execution_json).to eq(requirement.to_h)
  end
end
