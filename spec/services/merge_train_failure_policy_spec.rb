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
