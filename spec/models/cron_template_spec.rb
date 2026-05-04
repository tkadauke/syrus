require "rails_helper"

RSpec.describe CronTemplate do
  let(:user) { Factories.user }

  def build_template(**overrides)
    described_class.new({
      user: user,
      name: "Weekly dependency bump",
      prompt: "Bump outdated dependencies in Gemfile.",
      cron_expression: "0 9 * * 1",
      pr_pileup_policy: "skip"
    }.merge(overrides))
  end

  describe "validation" do
    it "is valid with reasonable defaults" do
      expect(build_template).to be_valid
    end

    it "requires a name" do
      expect(build_template(name: "")).not_to be_valid
    end

    it "requires a prompt" do
      expect(build_template(prompt: "")).not_to be_valid
    end

    it "requires a cron_expression" do
      t = build_template(cron_expression: nil)
      expect(t).not_to be_valid
      expect(t.errors[:cron_expression]).to be_present
    end

    it "rejects unknown pr_pileup_policy" do
      expect(build_template(pr_pileup_policy: "merge")).not_to be_valid
    end

    it "rejects a cron expression that fires more than once per hour" do
      t = build_template(cron_expression: "*/30 * * * *")
      expect(t).not_to be_valid
      expect(t.errors[:cron_expression].join).to match(/at most once per hour/)
    end

    it "rejects a malformed cron expression" do
      expect(build_template(cron_expression: "bogus")).not_to be_valid
    end

    it "accepts all valid pileup policies" do
      CronTemplate::PR_PILEUP_POLICIES.each do |policy|
        expect(build_template(pr_pileup_policy: policy)).to be_valid
      end
    end
  end

  describe "enabled flag" do
    it "defaults to true" do
      t = build_template
      t.save!
      expect(t.reload.enabled).to be true
    end

    it "can be set to false" do
      t = build_template(enabled: false)
      t.save!
      expect(t.reload.enabled).to be false
    end
  end

  describe ".enabled_only scope" do
    it "returns only enabled templates" do
      enabled = build_template.tap(&:save!)
      disabled = build_template(name: "Disabled one", enabled: false).tap(&:save!)
      expect(described_class.enabled_only).to include(enabled)
      expect(described_class.enabled_only).not_to include(disabled)
    end
  end

  describe "associations" do
    it "has many scheduled_tasks that nullify on destroy" do
      template = build_template.tap(&:save!)
      repo = Factories.repository(user: user)
      task = repo.scheduled_tasks.create!(
        user: user, name: "T", kind: "cron",
        cron_expression: "0 9 * * 1", pr_pileup_policy: "skip",
        prompt: "p", cron_template: template
      )
      template.destroy!
      expect(task.reload.cron_template_id).to be_nil
    end
  end
end
