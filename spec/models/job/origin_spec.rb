require "rails_helper"

# Job Origin (docs/plans/plugin-model-and-component-moves.md).
#
# `origin` names the plugin that created the Job and `origin_id` is that
# plugin's own identifier for the thing that caused it. The point of routing
# resolution through the registry rather than a column is that a disabled or
# uninstalled plugin degrades to plain text instead of leaving a dangling
# reference -- which is what `jobs.scheduled_task_id` can never do.
RSpec.describe Job::Origin do
  let(:repo) { Factories.repository }

  describe "population on create" do
    it "records a scheduled fire against the task that caused it" do
      job = Factories.job_record(repository: repo, kind: "cron", issue_number: nil, scheduled_task_id: 7)

      expect(job.origin).to eq("scheduled_tasks")
      expect(job.origin_id).to eq("7")
    end

    it "records an issue-backed Job against the source plugin" do
      job = Factories.job_record(repository: repo, issue_number: 42)

      expect(job.origin).to eq("github_source")
      expect(job.origin_id).to eq("42")
    end

    it "records a typed prompt as core, with nothing to point at" do
      job = Factories.job_record(repository: repo, kind: "direct", issue_number: nil)

      expect(job.origin).to eq("core")
      expect(job.origin_id).to be_nil
    end

    it "leaves an origin the caller set explicitly alone" do
      job = Factories.job_record(repository: repo, kind: "direct", issue_number: nil,
                                 origin: "agent_insights", origin_id: "99")

      expect(job.origin).to eq("agent_insights")
      expect(job.origin_id).to eq("99")
    end
  end

  describe "resolution through the owning plugin" do
    let(:provider) do
      Class.new do
        include Syrus::Plugin::JobOrigin
        def self.origin_key = "test_origin"
        def self.label(origin_id:, repository: nil) = "Nightly sweep ##{origin_id}"
        def self.url(origin_id:, repository: nil) = "/scheduled_tasks/#{origin_id}"
      end
    end
    let(:job) { Factories.job_record(repository: repo, kind: "direct", issue_number: nil, origin: "test_origin", origin_id: "12") }

    before do
      allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
      allow(Syrus::PluginRegistry).to receive(:providers_for).with(:job_origin).and_return([ provider ])
    end

    it "asks the plugin for the label and the link" do
      expect(described_class.label(job)).to eq("Nightly sweep #12")
      expect(described_class.url(job)).to eq("/scheduled_tasks/12")
    end
  end

  describe "when no plugin claims the origin" do
    let(:job) { Factories.job_record(repository: repo, kind: "direct", issue_number: nil, origin: "uninstalled", origin_id: "12") }

    before do
      allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
      allow(Syrus::PluginRegistry).to receive(:providers_for).with(:job_origin).and_return([])
    end

    # The disabled/uninstalled case is the whole reason this is a registry
    # lookup and not a foreign key.
    it "degrades to the raw identifier rather than crashing" do
      expect(described_class.label(job)).to eq("12")
      expect(described_class.url(job)).to be_nil
    end
  end

  describe "when the plugin raises" do
    let(:provider) do
      Class.new do
        include Syrus::Plugin::JobOrigin
        def self.origin_key = "broken"
        def self.label(origin_id:, repository: nil) = raise("boom")
        def self.url(origin_id:, repository: nil) = raise("boom")
      end
    end
    let(:job) { Factories.job_record(repository: repo, kind: "direct", issue_number: nil, origin: "broken", origin_id: "5") }

    before do
      allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
      allow(Syrus::PluginRegistry).to receive(:providers_for).with(:job_origin).and_return([ provider ])
    end

    # Rendering a Job must not depend on a plugin behaving.
    it "falls back instead of taking the page down" do
      expect(described_class.label(job)).to eq("5")
      expect(described_class.url(job)).to be_nil
    end
  end
end
