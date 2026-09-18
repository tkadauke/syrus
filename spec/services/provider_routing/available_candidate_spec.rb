require "rails_helper"

RSpec.describe ProviderRouting::AvailableCandidate do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, job_provider_setting: "default") }

  def stub_availability(provider, payload)
    allow(App::ProviderAvailability).to receive(:for_user).with(user, provider, now: anything).and_return(payload)
  end

  def rule!(candidates)
    ProviderRoutingRule.create!(scope_type: "repository", scope_id: repository.id, task_key: "ci_failure", candidates: candidates)
  end

  describe "first-candidate-available selection" do
    it "walks past unavailable candidates and returns the first one that is available" do
      rule!([ { "provider" => "codex" }, { "provider" => "claude" } ])
      stub_availability("codex", { "state" => "rate_limited", "open" => true })
      stub_availability("claude", nil)

      result = described_class.call(job: job, task_key: "ci_failure")

      expect(result).to be_available
      expect(result.candidate.provider).to eq("claude")
    end

    it "returns the top candidate untouched when it is already available" do
      rule!([ { "provider" => "claude" }, { "provider" => "codex" } ])
      stub_availability("claude", nil)

      result = described_class.call(job: job, task_key: "ci_failure")

      expect(result).to be_available
      expect(result.candidate.provider).to eq("claude")
    end
  end

  describe "candidate list exhaustion" do
    it "returns the top candidate with available: false when every candidate is unavailable" do
      rule!([ { "provider" => "codex" }, { "provider" => "claude" } ])
      stub_availability("codex", { "state" => "rate_limited", "open" => true })
      stub_availability("claude", { "state" => "exhausted", "usage_exhausted" => true })

      result = described_class.call(job: job, task_key: "ci_failure")

      expect(result).not_to be_available
      expect(result.candidate.provider).to eq("codex")
      expect(result.candidates.map(&:provider)).to eq(%w[ codex claude ])
    end
  end
end
