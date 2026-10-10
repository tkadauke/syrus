require "rails_helper"

RSpec.describe MergeTrainFailurePolicy do
  let(:repository) { instance_double(Repository, merge_train_failure_policy_ladder: nil) }

  it "uses a repository ladder when one is configured" do
    repository = instance_double(Repository, merge_train_failure_policy_ladder: [ "keep_assembly" ])

    policy = described_class.resolve(repository: repository, attempt_number: 1, retry_classification: "worker_died")

    expect(policy).to be_a(MergeTrainFailurePolicy::Rungs::KeepAssembly)
  end

  it "falls back to the instance default when the repository has no ladder" do
    AppSetting.current.update!(merge_train_failure_policy: "keep_assembly")

    policy = described_class.resolve(repository: repository, attempt_number: 1, retry_classification: "worker_died")

    expect(policy).to be_a(MergeTrainFailurePolicy::Rungs::KeepAssembly)
  end

  it "keeps using the instance default on later attempts when the repository has no ladder" do
    AppSetting.current.update!(merge_train_failure_policy: "keep_assembly")

    policy = described_class.resolve(repository: repository, attempt_number: 2, retry_classification: "worker_died")

    expect(policy).to be_a(MergeTrainFailurePolicy::Rungs::KeepAssembly)
  end

  it "maps attempts to ordered rungs" do
    repository = instance_double(Repository, merge_train_failure_policy_ladder: [ "restart", "keep_assembly" ])

    policy = described_class.resolve(repository: repository, attempt_number: 2, retry_classification: "worker_died")

    expect(policy).to be_a(MergeTrainFailurePolicy::Rungs::KeepAssembly)
  end

  it "falls back to restart when the attempt is past the ladder" do
    repository = instance_double(Repository, merge_train_failure_policy_ladder: [ "keep_assembly" ])

    policy = described_class.resolve(repository: repository, attempt_number: 2, retry_classification: "worker_died")

    expect(policy).to be_a(MergeTrainFailurePolicy::Rungs::Restart)
  end

  it "skips unknown rungs instead of raising" do
    repository = instance_double(Repository, merge_train_failure_policy_ladder: [ "future_rung", "keep_assembly" ])

    policy = described_class.resolve(repository: repository, attempt_number: 1, retry_classification: "worker_died")

    expect(policy).to be_a(MergeTrainFailurePolicy::Rungs::KeepAssembly)
  end

  it "stops walking at the retry budget" do
    repository = instance_double(Repository, merge_train_failure_policy_ladder: [ "future_1", "future_2", "future_3", "keep_assembly" ])

    policy = described_class.resolve(repository: repository, attempt_number: 1, retry_classification: "rate_limited")

    expect(policy).to be_a(MergeTrainFailurePolicy::Rungs::Restart)
  end
end
