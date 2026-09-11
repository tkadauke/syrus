require "rails_helper"
require "fileutils"
require "tmpdir"

RSpec.describe SyrusMcp::RunTargetPrepareTool do
  let(:run) { Factories.job.initial_run }
  let(:workflow) { run.workflow }
  let(:workspace_path) { WorkflowWorkspace.path_for(workflow) }

  around do |example|
    original_data_root = ENV["SYRUS_DATA_ROOT"]
    Dir.mktmpdir("syrus-run-target-prepare") do |data_root|
      ENV["SYRUS_DATA_ROOT"] = data_root
      FileUtils.rm_rf(workspace_path)
      FileUtils.mkdir_p(workspace_path)
      example.run
    ensure
      FileUtils.rm_rf(workspace_path)
      ENV["SYRUS_DATA_ROOT"] = original_data_root
    end
  end

  def call_tool(label, reason: "need project deps")
    described_class.call(label: label, reason: reason, server_context: { run_id: run.id })
  end

  it "runs a nested prepare target from the target project directory and records an audit artifact" do
    FileUtils.mkdir_p(workspace_path.join("cli"))
    workspace_path.join("cli/.syrus.yml").write(<<~YAML)
      prepare:
        - pwd > prepared-from.txt
        - printf ready > prepared.txt
    YAML

    response = call_tool("//cli:prepare")

    expect(response).not_to be_error
    expect(workspace_path.join("cli/prepared.txt").read).to eq("ready")
    expect(workspace_path.join("cli/prepared-from.txt").read.strip).to eq(workspace_path.join("cli").to_s)

    request = workflow.reload.artifact("target_prepare_requests").last
    expect(request).to include(
      "label" => "//cli:prepare",
      "reason" => "need project deps",
      "status" => "succeeded",
      "owner_config_path" => "cli/.syrus.yml",
      "project_id" => "cli",
      "workdir" => workspace_path.join("cli").to_s
    )
    expect(request["commands"]).to eq([ "pwd > prepared-from.txt", "printf ready > prepared.txt" ])
    expect(request["command_results"].map { |result| result["exit_status"] }).to eq([ 0, 0 ])
  end

  it "returns an error and audits the failed command when target prepare fails" do
    workspace_path.join(".syrus.yml").write(<<~YAML)
      prepare:
        - printf before-fail
        - exit 7
    YAML

    response = call_tool("//:prepare")

    expect(response).to be_error
    request = workflow.reload.artifact("target_prepare_requests").last
    expect(request["status"]).to eq("failed")
    expect(request["command_results"].last).to include("command" => "exit 7", "exit_status" => 7)
    expect(request["output_tail"]).to include("before-fail")
  end

  it "rejects non-prepare targets" do
    workspace_path.join(".syrus.yml").write(<<~YAML)
      grade:
        - name: tests
          run: bin/rspec
    YAML

    response = call_tool("//:grade/tests")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("not a prepare target")
    expect(workflow.reload.artifact("target_prepare_requests")).to be_nil
  end

  it "is not available to reviewer roles" do
    run.step.update!(kind: "adversarial_review")
    workspace_path.join(".syrus.yml").write("prepare:\n  - true\n")

    response = call_tool("//:prepare")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("not_authorized")
  end
end
