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

  def add_windows_target(graph)
    graph.add_target(
      TargetGraph::Target.new(
        label: TargetGraph::Label.parse("//windows:grade/package"),
        kind: "grader",
        project_id: "repo",
        source_scope: [ "windows/**/*" ],
        command: "msbuild",
        capabilities: TargetGraph::ExecutionCapabilities.new(os: "windows", arch: [ "x64" ])
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

  it "reports an equal-weight target mismatch even when the first max target is satisfied" do
    workflow.update!(
      planned_execution_capabilities: { "os" => [ "macos" ], "toolchains" => [ "xcode" ] },
      planned_execution_source: "inferred"
    )
    graph = add_windows_target(graph_with_targets)

    result = described_class.call(
      workflow: workflow,
      graph: graph,
      changed_files: [ "ios/App/View.swift", "windows/App/App.sln" ]
    )

    expect(result).to be_escalated
    expect(result.most_constrained_targets.map { |target| target.fetch("target_label") }).to contain_exactly(
      "//ios:grade/ui",
      "//windows:grade/package"
    )
    expect(result.mismatched_targets.map { |target| target.fetch("target_label") })
      .to eq([ "//windows:grade/package" ])
    expect(result.required_capabilities).to eq("os" => [ "windows" ], "arch" => [ "x64" ])
    expect(result.mismatches).to include(
      include("target_label" => "//windows:grade/package", "dimension" => "os", "missing" => [ "windows" ]),
      include("target_label" => "//windows:grade/package", "dimension" => "arch", "missing" => [ "x64" ])
    )
  end
end
