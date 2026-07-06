require "rails_helper"

RSpec.describe PrPileupPolicies do
  describe ".for" do
    it "returns SkipPolicy for 'skip'" do
      expect(described_class.for("skip")).to eq(PrPileupPolicies::SkipPolicy)
    end

    it "returns ReplacePolicy for 'replace'" do
      expect(described_class.for("replace")).to eq(PrPileupPolicies::ReplacePolicy)
    end

    it "returns PilePolicy for 'pile'" do
      expect(described_class.for("pile")).to eq(PrPileupPolicies::PilePolicy)
    end

    it "raises ConfigurationError for unknown policy names" do
      expect { described_class.for("queue") }
        .to raise_error(PrPileupPolicies::ConfigurationError, /Unknown pr_pileup_policy/)
    end
  end

  describe PrPileupPolicies::SkipPolicy do
    let(:user) { Factories.user(github_token: "ghp_x") }
    let(:repository) { Factories.repository(user: user) }
    let(:task) do
      ScheduledTask.create!(
        user: user, repository: repository,
        name: "Weekly scan", prompt: "Scan it.",
        kind: "cron", cron_expression: "0 9 * * 1", pr_pileup_policy: "skip"
      )
    end
    let(:fire_service) { instance_double(ScheduledTaskFire, now: Time.current) }

    it "returns nil when no open PR exists" do
      allow(task).to receive(:has_open_pr?).and_return(false)
      policy = described_class.new(task, fire_service: fire_service)
      expect(policy.check_pileup).to be_nil
    end

    it "returns a skipped Result and stamps the fire when a prior PR is open" do
      allow(task).to receive(:has_open_pr?).and_return(true)
      allow(task).to receive(:record_fire!)
      policy = described_class.new(task, fire_service: fire_service)

      result = policy.check_pileup
      expect(result).not_to be_nil
      expect(result.skipped).to be true
      expect(result.reason).to eq("prior_pr_open")
    end
  end

  describe PrPileupPolicies::ReplacePolicy do
    it "delegates to fire_service.close_prior_open_prs and returns nil" do
      fire_service = instance_double(ScheduledTaskFire, close_prior_open_prs: nil)
      task = instance_double(ScheduledTask)
      policy = described_class.new(task, fire_service: fire_service)

      expect(fire_service).to receive(:close_prior_open_prs)
      expect(policy.check_pileup).to be_nil
    end
  end

  describe PrPileupPolicies::PilePolicy do
    it "always returns nil (fire proceeds)" do
      fire_service = instance_double(ScheduledTaskFire)
      task = instance_double(ScheduledTask)
      policy = described_class.new(task, fire_service: fire_service)

      expect(policy.check_pileup).to be_nil
    end
  end
end
