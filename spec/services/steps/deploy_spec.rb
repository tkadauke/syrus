require "rails_helper"
require "tmpdir"

RSpec.describe Steps::Deploy do
  let(:job)      { Factories.job }
  let(:workflow) { Workflows::Deploy.instantiate(job: job) }
  let(:step)     { workflow.steps.find_by!(kind: "deploy") }
  let(:run)      { step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind) }
  let(:handler)  { described_class.new(run) }

  around do |ex|
    Dir.mktmpdir("syrus-deploy") do |dir|
      @ws_path = Pathname.new(dir)
      ex.run
    end
  end

  before do
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(handler).to receive(:workspace).and_return(fake_ws)
  end

  it "runs the configured deploy.run command" do
    File.write(@ws_path.join(".syrus.yml"), <<~YAML)
      deploy:
        run: echo deploying now
    YAML

    handler.call

    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("$ echo deploying now")
    expect(chunks).to include("deploying now")
    expect(chunks).to include("deploy command completed successfully")
    expect(step.reload.details.to_h["deploy_failure"]).to be_nil
    expect(workflow.reload.artifact("deploy_failure")).to be_nil
  end

  it "raises StepFailed and records deploy_failure when the command fails" do
    File.write(@ws_path.join(".syrus.yml"), <<~YAML)
      deploy:
        run: exit 3
    YAML

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /deploy command failed \(exit 3\)/)

    failure = step.reload.details["deploy_failure"]
    expect(failure).to include("command" => "exit 3", "exit_status" => 3)
    expect(workflow.reload.artifact("deploy_failure")).to include("command" => "exit 3")
  end

  it "raises StepFailed when .syrus.yml has no deploy: block configured" do
    File.write(@ws_path.join(".syrus.yml"), "grade: []\n")

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /no deploy\.run command configured/)
  end

  it "raises StepFailed when .syrus.yml is missing entirely" do
    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /no \.syrus\.yml found/)
  end

  it "raises StepFailed when .syrus.yml fails to parse" do
    File.write(@ws_path.join(".syrus.yml"), "deploy: [not, a, mapping]\n")

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /\.syrus\.yml could not be parsed/)
  end
end
