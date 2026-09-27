require "rails_helper"
require "tmpdir"

RSpec.describe Syrus::NotableChangeDetection do
  let(:job) { Factories.job_with_run }
  let(:workflow) { job.workflows.first }
  let(:provider) do
    Class.new do
      include Syrus::Plugin::NotableChangeDetector

      def self.detector_key = "spec"

      def self.detect(workflow:, diff:, changed_files:, name_status:, workspace_path:)
        [
          {
            key: "spec:changed",
            severity: "fyi",
            summary: "Spec changed.",
            evidence: changed_files.map { |file| { file: file } }
          }
        ]
      end
    end
  end

  after { Syrus::PluginRegistry.reset! }

  it "invokes registered detectors against the workflow diff and publishes facts" do
    Syrus::PluginRegistry.register(:notable_change_detector, provider)
    allow(Syrus::Events).to receive(:known?).and_call_original
    allow(Syrus::Events).to receive(:known?).with(described_class::EVENT_NAME).and_return(true)
    expect(Syrus::Events).to receive(:publish).with(
      described_class::EVENT_NAME,
      hash_including(
        workflow_id: workflow.id,
        job_id: job.id,
        repository_id: job.repository_id,
        facts: [
          {
            "key" => "spec:changed",
            "severity" => "fyi",
            "summary" => "Spec changed.",
            "evidence" => [ { "file" => "Gemfile.lock" } ]
          }
        ]
      )
    )

    Dir.mktmpdir("syrus-notable-change") do |dir|
      path = Pathname.new(dir)
      path.join(".git").mkpath
      allow(WorkflowWorkspace).to receive(:path_for).with(workflow).and_return(path)
      allow(WorkflowWorkspace).to receive(:base_ref_for).with(job, workflow: workflow).and_return("origin/main")
      git = instance_double(
        GitRunner,
        run: "diff --git a/Gemfile.lock b/Gemfile.lock\n"
      )
      allow(git).to receive(:run).with("diff", "origin/main...HEAD", chdir: path.to_s).and_return("diff --git a/Gemfile.lock b/Gemfile.lock\n")
      allow(git).to receive(:run).with("diff", "--name-only", "origin/main...HEAD", chdir: path.to_s).and_return("Gemfile.lock\n")
      allow(git).to receive(:run).with("diff", "--name-status", "origin/main...HEAD", chdir: path.to_s).and_return("M\tGemfile.lock\n")

      described_class.new(workflow, git: git).detect!
    end
  end
end
