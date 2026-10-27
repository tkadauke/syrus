require "rails_helper"

RSpec.describe MergeTrainFailurePolicy do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def stub_ladder(rungs)
    content = rungs ? "merge_train:\n  failure_policy:\n#{rungs.map { |rung| "    - #{rung}" }.join("\n")}\n" : nil
    stub_repository_content(repository, files: content ? { SyrusYml::CONFIG_FILE => content } : {})
  end

  it "uses a repository ladder when one is configured" do
    stub_ladder([ "keep_assembly" ])

    policy = described_class.resolve(repository: repository, attempt_number: 1, retry_classification: "worker_died")

    expect(policy).to be_a(MergeTrainFailurePolicy::Rungs::KeepAssembly)
  end

  describe "rung behaviour" do
    # These two levers are what make the three rung names three rungs. While
    # KeepFixes subclassed KeepAssembly and added nothing, a ladder listing both
    # escalated from a rung to its own duplicate.
    it "separates keeping the assembly from keeping the branch for replay" do
      restart = MergeTrainFailurePolicy::Rungs::Restart.new
      keep_assembly = MergeTrainFailurePolicy::Rungs::KeepAssembly.new
      keep_fixes = MergeTrainFailurePolicy::Rungs::KeepFixes.new

      expect(restart.preserve_train?(preservable_failure: true)).to be(false)
      expect(keep_assembly.preserve_train?(preservable_failure: true)).to be(true)
      expect(keep_fixes.preserve_train?(preservable_failure: true)).to be(true)

      expect(restart.preserve_branch_for_replay?).to be(false)
      expect(keep_assembly.preserve_branch_for_replay?).to be(false)
      expect(keep_fixes.preserve_branch_for_replay?).to be(true)
    end

    it "never preserves the assembly for a member-attributable failure" do
      [
        MergeTrainFailurePolicy::Rungs::Restart,
        MergeTrainFailurePolicy::Rungs::KeepAssembly,
        MergeTrainFailurePolicy::Rungs::KeepFixes
      ].each do |rung_class|
        expect(rung_class.new.preserve_train?(preservable_failure: false)).to be(false),
          "#{rung_class.name} must not preserve an assembly around a member's own failure"
      end
    end

    # keep_fixes and keep_assembly must stay distinguishable by name as well as
    # behaviour -- the ladder is configured by name.
    it "keeps the three rung names distinct" do
      expect(MergeTrainFailurePolicy::IMPLEMENTED_RUNGS.keys).to contain_exactly("restart", "keep_assembly", "keep_fixes")
    end
  end

  # The budget used to be checked only on the configured-ladder path, so a
  # repository without a ladder got the instance default on attempt 1 and on
  # attempt 50 alike. Harmless while preservation did nothing; once a preserved
  # train is actually relaunched, a `keep_assembly` default with no cap is a
  # train that preserves itself forever.
  it "stops using the instance default once the retry budget is spent" do
    AppSetting.current.update!(merge_train_failure_policy: "keep_assembly")
    stub_ladder(nil)
    limit = AutoRetryAttempt.retry_budget_limit_for("worker_died")

    within_budget = described_class.resolve(repository: repository, attempt_number: limit, retry_classification: "worker_died")
    past_budget = described_class.resolve(repository: repository, attempt_number: limit + 1, retry_classification: "worker_died")

    expect(within_budget).to be_a(MergeTrainFailurePolicy::Rungs::KeepAssembly)
    expect(past_budget).to be_a(MergeTrainFailurePolicy::Rungs::Restart)
  end

  it "falls back to the instance default when the repository has no ladder" do
    AppSetting.current.update!(merge_train_failure_policy: "keep_assembly")
    stub_ladder(nil)

    policy = described_class.resolve(repository: repository, attempt_number: 1, retry_classification: "worker_died")

    expect(policy).to be_a(MergeTrainFailurePolicy::Rungs::KeepAssembly)
  end

  it "keeps using the instance default on later attempts when the repository has no ladder" do
    AppSetting.current.update!(merge_train_failure_policy: "keep_assembly")
    stub_ladder(nil)

    policy = described_class.resolve(repository: repository, attempt_number: 2, retry_classification: "worker_died")

    expect(policy).to be_a(MergeTrainFailurePolicy::Rungs::KeepAssembly)
  end

  it "uses restart when the repository .syrus.yml is invalid" do
    AppSetting.current.update!(merge_train_failure_policy: "keep_assembly")
    stub_repository_content(repository, files: { SyrusYml::CONFIG_FILE => "merge_train: [nope]\n" })

    policy = described_class.resolve(repository: repository, attempt_number: 1, retry_classification: "worker_died")

    expect(policy).to be_a(MergeTrainFailurePolicy::Rungs::Restart)
  end

  it "uses restart when the repository .syrus.yml cannot be read" do
    AppSetting.current.update!(merge_train_failure_policy: "keep_assembly")
    stub_repository_content_failure(repository, RepositoryContent::Unavailable.new("rate limited"))

    policy = described_class.resolve(repository: repository, attempt_number: 1, retry_classification: "worker_died")

    expect(policy).to be_a(MergeTrainFailurePolicy::Rungs::Restart)
  end

  it "maps attempts to ordered rungs" do
    stub_ladder([ "restart", "keep_assembly" ])

    policy = described_class.resolve(repository: repository, attempt_number: 2, retry_classification: "worker_died")

    expect(policy).to be_a(MergeTrainFailurePolicy::Rungs::KeepAssembly)
  end

  it "falls back to restart when the attempt is past the ladder" do
    stub_ladder([ "keep_assembly" ])

    policy = described_class.resolve(repository: repository, attempt_number: 2, retry_classification: "worker_died")

    expect(policy).to be_a(MergeTrainFailurePolicy::Rungs::Restart)
  end

  it "skips unknown rungs instead of raising" do
    stub_ladder([ "future_rung", "keep_assembly" ])

    policy = described_class.resolve(repository: repository, attempt_number: 1, retry_classification: "worker_died")

    expect(policy).to be_a(MergeTrainFailurePolicy::Rungs::KeepAssembly)
  end

  it "stops walking at the retry budget" do
    stub_ladder([ "future_1", "future_2", "future_3", "keep_assembly" ])

    policy = described_class.resolve(repository: repository, attempt_number: 1, retry_classification: "rate_limited")

    expect(policy).to be_a(MergeTrainFailurePolicy::Rungs::Restart)
  end
end
