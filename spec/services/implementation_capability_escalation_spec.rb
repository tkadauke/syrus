require "rails_helper"

RSpec.describe ImplementationCapabilityEscalation do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }
  let(:workflow) { Workflow.create!(job: job, user: user, trigger_kind: "initial", agent_provider: job.agent_provider) }

  def graph_with_targets
    graph = TargetGraph.new
    graph.add_target(
      TargetGraph::Target.new(
        label: TargetGraph::Label.parse("//ios:grade/ui"),
        kind: "grader",
        project_id: "repo",
        source_scope: [ "ios/**/*" ],
        command: "xcodebuild test",
        capabilities: TargetGraph::ExecutionCapabilities.new(os: "macos", toolchains: [ "xcode" ])
      )
    )
    graph.add_target(
      TargetGraph::Target.new(
        label: TargetGraph::Label.parse("//backend:grade/specs"),
        kind: "grader",
        project_id: "repo",
        source_scope: [ "app/**/*" ],
        command: "bin/rspec",
        capabilities: TargetGraph::ExecutionCapabilities.new(os: "linux")
      )
    )
    graph
  end

  it "reports escalation when a Linux-planned implementation touches a Mac-only target" do
    workflow.update!(
      planned_execution_capabilities: { "os" => [ "linux" ] },
      planned_execution_source: "defaulted"
    )

    result = described_class.call(
      workflow: workflow,
      graph: graph_with_targets,
      changed_files: [ "ios/App/View.swift" ]
    )

    expect(result).to be_escalated
    expect(result.required_capabilities).to eq("os" => [ "macos" ], "toolchains" => [ "xcode" ])
    expect(result.mismatches).to include(
      include("dimension" => "os", "planned" => [ "linux" ], "required" => [ "macos" ], "missing" => [ "macos" ]),
      include("dimension" => "toolchains", "planned" => [], "required" => [ "xcode" ], "missing" => [ "xcode" ])
    )
  end

  it "does not warn for mixed changes when the primary plan satisfies the most constrained target" do
    workflow.update!(
      planned_execution_capabilities: { "os" => [ "macos" ], "toolchains" => [ "xcode" ] },
      planned_execution_source: "inferred"
    )

    result = described_class.call(
      workflow: workflow,
      graph: graph_with_targets,
      changed_files: [ "ios/App/View.swift", "app/models/user.rb" ]
    )

    expect(result).not_to be_escalated
    expect(result.most_constrained_target.fetch("target_label")).to eq("//ios:grade/ui")
  end
end
