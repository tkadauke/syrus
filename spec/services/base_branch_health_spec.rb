require "rails_helper"

RSpec.describe BaseBranchHealth do
  let!(:repository) { Factories.repository }
  let!(:job) { Factories.job_record(repository: repository) }

  context "with a provider" do
    it "answers from the registered provider" do
      provider = Class.new do
        def self.repair_job?(job) = job.present?
        def self.checks = :checks
      end
      allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:base_branch_health).and_return([ provider ])

      expect(described_class.repair_job?(job)).to be(true)
      expect(described_class.checks).to eq(:checks)
    end
  end

  context "with no provider" do
    before { allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:base_branch_health).and_return([]) }

    it "knows nothing and does nothing" do
      expect(described_class.monitoring_enabled?(repository)).to be(false)
      expect(described_class.repair_job?(job)).to be(false)
      expect(described_class.stuck_repair_job(repository)).to be_nil
      expect(described_class.settled_ci_health).to eq([])
      expect { described_class.poll_later(repository.id) }.not_to raise_error
      expect { described_class.ensure_repair!(repository) }.not_to raise_error
      expect { described_class.health_changed!(repository) }.not_to raise_error
      expect { described_class.repair_job_closed(job) }.not_to raise_error
    end

    it "returns empty chainable records" do
      expect(described_class.checks.where(repository: repository).recent.first).to be_nil
      expect(described_class.checks.where(sha: "abc").exists?).to be(false)
      expect(described_class.concern_reports.where(run: nil).none).to be_blank
      expect { described_class.checks.create!(sha: "abc") }.to raise_error(NotImplementedError)
    end
  end

  it "fails open when the provider raises" do
    provider = Class.new { def self.repair_job?(_job) = raise("boom") }
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:base_branch_health).and_return([ provider ])

    expect(described_class.repair_job?(job)).to be(false)
  end
end
