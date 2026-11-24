require "rails_helper"

RSpec.describe MainBranchFailureClassifier do
  describe MainBranchFailureClassifier::LandingBaseSha do
    let(:job) { Factories.job }
    let(:workflow) { job.workflows.first }

    it "uses the current mergeability base for auto-merge workflows" do
      workflow.update!(trigger_kind: "auto_merge")
      job.update!(mergeability_base_sha: "current-base")

      expect(described_class.for(workflow).value).to eq("current-base")
    end

    it "uses the built integration base for merge-train workflows" do
      workflow.update!(trigger_kind: "merge_train")
      workflow.set_artifact!("merge_train_base_sha", "train-base")

      expect(described_class.for(workflow).value).to eq("train-base")
    end

    it "uses the predicted base for speculative landing validations" do
      workflow.update!(trigger_kind: "landing_validation")
      workflow.set_artifact!("predicted_base_sha", "predicted-base")

      expect(described_class.for(workflow).value).to eq("predicted-base")
    end

    it "falls back to the repository's last health-checked revision" do
      job.repository.update!(last_health_checked_sha: "healthy-base")

      expect(described_class.for(workflow).value).to eq("healthy-base")
    end
  end

  # Regression: a merge train failed every rspec-ci shard on failures main was
  # already failing, yet each shard was compared only with the base shard of
  # the same name. The train added spec files, the runtime grouping shifted
  # them between shards, and a test main failed in shard 2 counted as
  # introduced when the train failed it in shard 3 -- five landing_fix rounds
  # on failures the train could not fix.
  describe "sharded graders" do
    let(:repository) { Factories.repository(main_branch_health_enabled: true) }
    let(:job) { Factories.job_record(repository: repository, state: "landing") }
    let(:base_job) { Factories.job_record(repository: repository, state: "running", issue_number: 2) }
    let(:workflow) do
      Workflow.create!(job: job, trigger_kind: "merge_train", state: "running", artifacts: { "merge_train_base_sha" => "base123" })
    end
    let(:base_workflow) { Workflow.create!(job: base_job, trigger_kind: "main_grader", state: "succeeded") }

    def failed_shard(owner, name, position)
      step = Step.create!(workflow: owner, kind: "grader", position: position, state: "failed",
                          details: { "name" => name, "failures" => "allow_inherited", "base_retry" => { "strategy" => "plugin" } })
      run = step.runs.create!(job: owner.job, trigger_kind: owner.trigger_kind, state: "failed")
      [ step, run ]
    end

    def stub_failures(by_run_id)
      provider = Class.new do
        class << self
          attr_accessor :failures
        end
        def self.test_case_count(run:, grader_name:) = failures.fetch(run.id, []).size + 1
        def self.failed_test_identities(run:, grader_name:) = failures.fetch(run.id, [])
      end
      provider.failures = by_run_id
      allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
      allow(Syrus::PluginRegistry).to receive(:providers_for).with(:test_evidence).and_return([ provider ])
    end

    it "treats a shard's failures as inherited when main failed them in a sibling shard" do
      _, base_one = failed_shard(base_workflow, "rspec-ci-1-of-4", 1)
      _, base_two = failed_shard(base_workflow, "rspec-ci-2-of-4", 2)
      MainBranchHealth::HealthCheck.record_grader_workflow(
        repository: repository, sha: "base123", grader_health: "broken",
        grader_failed_names: %w[rspec-ci-1-of-4 rspec-ci-2-of-4], workflow: base_workflow
      )
      shard_one, train_one = failed_shard(workflow, "rspec-ci-1-of-4", 1)
      shard_three, train_three = failed_shard(workflow, "rspec-ci-3-of-4", 3)
      stub_failures(
        base_one.id => [ "spec/a_spec.rb\0a" ], base_two.id => [ "spec/b_spec.rb\0b" ],
        train_one.id => [ "spec/a_spec.rb\0a" ], train_three.id => [ "spec/b_spec.rb\0b" ]
      )

      result = described_class.call(workflow: workflow, failed_grader_steps: [ shard_one, shard_three ])

      expect(result).to be_inherited
      expect(result.inherited_names).to contain_exactly("rspec-ci-1-of-4", "rspec-ci-3-of-4")
    end

    it "still reports a failure no shard of main had" do
      _, base_one = failed_shard(base_workflow, "rspec-ci-1-of-4", 1)
      MainBranchHealth::HealthCheck.record_grader_workflow(
        repository: repository, sha: "base123", grader_health: "broken",
        grader_failed_names: %w[rspec-ci-1-of-4], workflow: base_workflow
      )
      shard_three, train_three = failed_shard(workflow, "rspec-ci-3-of-4", 3)
      stub_failures(base_one.id => [ "spec/a_spec.rb\0a" ], train_three.id => [ "spec/new_spec.rb\0new" ])

      result = described_class.call(workflow: workflow, failed_grader_steps: [ shard_three ])

      expect(result).not_to be_inherited
      expect(result.new_names).to eq([ "rspec-ci-3-of-4" ])
    end
  end
end
