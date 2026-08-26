require "rails_helper"

RSpec.describe WorkDefinitions do
  it "defines every non-legacy workflow trigger kind" do
    expected = Workflow::TriggerKind.values - Workflow::TriggerKind.runtime_role_values("legacy")

    expect(described_class.registry.keys).to include(*expected)
  end

  it "keeps WorkDefinition metadata in sync with Workflow::TriggerKind" do
    described_class.registry.each do |kind, definition_class|
      definition = definition_class.new
      trigger_entry = Workflow::TriggerKind.fetch(definition.workflow_trigger_kind)

      expect(definition.kind).to eq(kind)
      expect(Workflow::TriggerKind.values).to include(definition.workflow_trigger_kind)
      expect(definition.runtime_role).to eq(trigger_entry.runtime_role)
      if definition.kind == definition.workflow_trigger_kind
        expect(definition.workflow_template).to eq(trigger_entry.template_class)
      else
        expect(definition.workflow_template.trigger_kind).to eq(definition.workflow_trigger_kind)
      end
      expect(definition.scope).to be_present
    end
  end

  it "defines checkpoint resume as a first-class retry work definition alias" do
    definition = described_class.for("checkpoint_resume")

    expect(definition.workflow_trigger_kind).to eq("retry")
    expect(definition.workflow_template).to eq(Workflows::CheckpointResume)
    expect(definition).to be_first_class
  end

  it "requires child workflow definitions to declare their parent kind" do
    child_definitions = described_class.registry.values.select { |definition_class| definition_class.runtime_role == "child" }

    expect(child_definitions).to all(have_attributes(parent_kind: be_present))
  end

  it "requires every work definition to declare scheduler policy hooks" do
    job = Factories.job_record

    described_class.registry.each_value do |definition_class|
      definition = definition_class.new

      expect(definition.review_publication_step_kinds).to respond_to(:each)
      expect(definition.intent_gates).to respond_to(:each)
      expect(definition.unit_gates).to respond_to(:each)
      expect(definition.scope_for(job: job, artifacts: {})).to have_attributes(type: be_present)
      expect(definition.members_for(job: job, artifacts: {})).to respond_to(:each)
      expect(definition.lock_keys_for(job: job, member_jobs: [])).to respond_to(:each)
      expect(definition.ref_metadata_for(job: job, artifacts: {})).to have_attributes(
        source_repository: job.effective_pr_repository,
        source_remote_kind: "repository",
        target_repository: job.effective_target_repository,
        target_remote_kind: "repository"
      )
      expect(definition.preemption_policy).to respond_to(:mode)
      expect(definition.preemption_policy).to respond_to(:checkpoint?)
      expect(definition.preemption_policy).to respond_to(:resume_strategy)
      expect(definition.retry_policy).to respond_to(:automatic?)
      expect(definition.retry_policy).to respond_to(:continuation?)
      expect(definition.retry_policy).to respond_to(:new_attempt?)
      expect(definition.retry_policy).to respond_to(:rebuild_unit?)
      expect(definition.recoverable_cancelled_workflow?).to be_in([ true, false ])
      expect(definition.suppresses_layered_auto_repair?).to be_in([ true, false ])
      expect(definition.manages_own_job_lifecycle?).to be_in([ true, false ])
    end
  end

  it "declares retry policies for workflow families" do
    resume_failed_step_kinds = %w[
      initial
      pr_comment
      chat_feedback
      ci_failure
      rebase
      stack_rebase
      auto_merge
      external_pr_merge
      retry
      checkpoint_resume
      manual_visual_review
      manual
      resume
      coding_handoff
      local_mode_handoff
      main_branch_repair
      manual_agentic_run
      external_pr_ingest
      external_pr_feedback
      skill
      deploy
      promotion
      hotfix_sync
    ]

    resume_failed_step_kinds.each do |kind|
      policy = described_class.for(kind).retry_policy

      expect(policy).to be_automatic
      expect(policy).to be_continuation(Step.new(kind: "pr_open"))
      expect(policy).not_to be_rebuild_unit(Step.new(kind: "merge_train_build"))
    end

    %w[merge_train job_bundle].each do |kind|
      merge_train_policy = described_class.for(kind).retry_policy
      expect(merge_train_policy).to be_automatic
      expect(merge_train_policy).to be_continuation(Step.new(kind: "merge_train_reconcile"))
      expect(merge_train_policy).to be_rebuild_unit(Step.new(kind: "merge_train_build"))
      expect(merge_train_policy).to be_rebuild_unit(Step.new(kind: "merge_train_land"))
    end

    operator_only_kinds = described_class.registry.keys - resume_failed_step_kinds - %w[merge_train job_bundle]
    operator_only_kinds.each do |kind|
      expect(described_class.for(kind).retry_policy).not_to be_automatic
    end
  end

  it "declares preemption policies for workflow families" do
    checkpoint_kinds = %w[
      initial
      pr_comment
      chat_feedback
      ci_failure
      retry
      checkpoint_resume
      manual
      resume
      coding_handoff
      local_mode_handoff
      main_branch_repair
      manual_agentic_run
      external_pr_ingest
      external_pr_feedback
      skill
      deploy
      promotion
      hotfix_sync
    ]
    rebuild_kinds = %w[
      rebase
      stack_rebase
      auto_merge
      external_pr_merge
      merge_train
      job_bundle
    ]
    cancel_kinds = %w[
      landing_validation
      merge_train_validation
      job_bundle_validation
      manual_visual_review
    ]

    checkpoint_kinds.each do |kind|
      policy = described_class.for(kind).preemption_policy

      expect(policy.mode).to eq(:checkpoint)
      expect(policy).to be_checkpoint
      expect(policy.resume_strategy).to eq(:checkpoint_resume)
    end

    rebuild_kinds.each do |kind|
      policy = described_class.for(kind).preemption_policy

      expect(policy.mode).to eq(:rebuild)
      expect(policy).not_to be_checkpoint
      expect(policy.resume_strategy).to eq(:rebuild_unit)
    end

    cancel_kinds.each do |kind|
      policy = described_class.for(kind).preemption_policy

      expect(policy.mode).to eq(:cancel)
      expect(policy).not_to be_checkpoint
      expect(policy.resume_strategy).to eq(:new_attempt)
    end

    none_kinds = described_class.registry.keys - checkpoint_kinds - rebuild_kinds - cancel_kinds
    none_kinds.each do |kind|
      policy = described_class.for(kind).preemption_policy

      expect(policy.mode).to eq(:none)
      expect(policy).not_to be_checkpoint
      expect(policy.resume_strategy).to eq(:none)
    end
  end

  it "declares review publication steps only for workflows that open review PRs" do
    expected_pr_openers = %w[
      initial
      retry
      checkpoint_resume
      coding_handoff
      local_mode_handoff
      main_branch_repair
      skill
    ]

    expected_pr_openers.each do |kind|
      expect(described_class.for(kind).review_publication_step_kinds).to eq(%w[pr_open])
    end

    (described_class.registry.keys - expected_pr_openers).each do |kind|
      expect(described_class.for(kind).review_publication_step_kinds).to eq([])
    end
  end

  it "publishes scheduler policy kind sets from work definitions" do
    expect(described_class.landing_lock_kinds).to contain_exactly(
      "auto_merge",
      "external_pr_merge",
      "merge_train",
      "job_bundle",
      "landing_validation",
      "merge_train_validation",
      "job_bundle_validation"
    )
    expect(described_class.landing_workflow_kinds).to contain_exactly(*Workflow::LANDING_TRIGGER_KINDS)
    expect(described_class.landing_work_unit_kinds).to contain_exactly(
      "auto_merge",
      "external_pr_merge",
      "merge_train",
      "job_bundle"
    )
    expect(described_class.epic_wide_kinds).to contain_exactly(*Workflow::EPIC_WIDE_TRIGGER_KINDS)
    expect(described_class.ci_failure_blocking_kinds).to contain_exactly(
      "rebase",
      "stack_rebase",
      "auto_merge",
      "external_pr_merge",
      "merge_train",
      "job_bundle",
      "landing_validation",
      "merge_train_validation",
      "job_bundle_validation"
    )
    expect(described_class.active_repair_work_kinds).to contain_exactly(
      "pr_comment",
      "chat_feedback",
      "ci_failure",
      "retry",
      "checkpoint_resume",
      "manual",
      "manual_agentic_run"
    )
    expect(described_class.retry_workflow_attempt_kinds).to contain_exactly(
      "retry",
      "checkpoint_resume"
    )
    expect(described_class.recoverable_cancelled_workflow_kinds).to contain_exactly(
      "initial",
      "pr_comment",
      "chat_feedback",
      "ci_failure",
      "retry",
      "checkpoint_resume",
      "replay",
      "manual",
      "resume",
      "coding_handoff",
      "local_mode_handoff",
      "external_pr_feedback",
      "deploy"
    )
    expect(described_class.layered_auto_repair_suppressed_kinds).to contain_exactly(
      "external_pr_ingest"
    )
    expect(described_class.landing_validation_prefetch_source_kinds).to contain_exactly(
      "auto_merge",
      "merge_train",
      "job_bundle"
    )
    expect(described_class.landing_validation_child_kinds).to contain_exactly(
      "landing_validation",
      "merge_train_validation",
      "job_bundle_validation"
    )
    expect(described_class.child_kinds_for("auto_merge")).to contain_exactly("landing_validation")
    expect(described_class.child_kinds_for("merge_train")).to contain_exactly("merge_train_validation")
    expect(described_class.child_kinds_for("job_bundle")).to contain_exactly("job_bundle_validation")
    expect(described_class.family_kinds_for("merge_train")).to contain_exactly("merge_train", "merge_train_validation")
    expect(described_class.family_kinds_for("job_bundle")).to contain_exactly("job_bundle", "job_bundle_validation")
    expect(described_class.landing_validation_child_kind_for("auto_merge")).to eq("landing_validation")
    expect(described_class.landing_validation_child_kind_for("merge_train")).to eq("merge_train_validation")
    expect(described_class.landing_validation_child_kind_for("job_bundle")).to eq("job_bundle_validation")
    expect(described_class.agent_concurrency_exempt_kinds).to contain_exactly(
      "main_grader",
      "main_branch_repair"
    )
    expect(described_class.lifecycle_managed_workflow_kinds).to contain_exactly(
      "main_grader",
      "agent_insight",
      "main_branch_repair",
      "landing_validation",
      "merge_train_validation",
      "promotion",
      "hotfix_sync"
    )
  end

  it "maps between WorkDefinition kinds and persisted Workflow trigger kinds" do
    expect(described_class.workflow_trigger_kinds_for(%w[merge_train job_bundle])).to eq(%w[merge_train])
    expect(described_class.workflow_trigger_kinds_for(%w[merge_train_validation job_bundle_validation])).to eq(%w[merge_train_validation])
    expect(described_class.workflow_trigger_kinds_for(%w[auto_merge stack_rebase])).to contain_exactly("auto_merge", "stack_rebase")

    expect(described_class.kinds_for_workflow_trigger("merge_train")).to contain_exactly("merge_train", "job_bundle")
    expect(described_class.kinds_for_workflow_trigger("merge_train_validation")).to contain_exactly("merge_train_validation", "job_bundle_validation")
  end

  it "keeps landing lock definitions behind their domain dispatchers" do
    described_class.registry.each_key do |kind|
      definition = described_class.for(kind)
      if definition.landing_lock?
        expect(definition.generic_intent_start_allowed?).to be(false), "#{definition.kind} must not bypass landing dispatch"
      else
        expect(definition.generic_intent_start_allowed?).to be(true), "#{definition.kind} should be generic-startable unless it declares a dispatcher"
      end
    end
  end

  it "resolves merge train members from the train artifact through the definition" do
    user = Factories.user
    repository = Factories.repository(user: user)
    epic = Factories.epic(user: user, repository: repository)
    first = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 101)
    second = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 102)
    train = MergeTrain.create!(epic: epic, repository: repository, base_branch: "main")
    MergeTrainMember.create!(merge_train: train, job: first, position: 0)
    MergeTrainMember.create!(merge_train: train, job: second, position: 1)

    definition = described_class.for("merge_train")

    expect(definition.scope_for(job: second, artifacts: { "merge_train_id" => train.id })).to have_attributes(type: "epic", id: epic.id)
    expect(definition.members_for(job: second, artifacts: { "merge_train_id" => train.id })).to eq([ first, second ])
  end

  it "resolves epicless job bundle members from the train artifact through the definition" do
    user = Factories.user
    repository = Factories.repository(user: user)
    first = Factories.job_record(user: user, repository: repository, issue_number: 101)
    second = Factories.job_record(user: user, repository: repository, issue_number: 102)
    train = MergeTrain.create!(repository: repository, base_branch: "main", priority: "medium")
    MergeTrainMember.create!(merge_train: train, job: first, position: 0)
    MergeTrainMember.create!(merge_train: train, job: second, position: 1)

    definition = described_class.for("job_bundle")

    expect(definition.label).to eq("Job bundle")
    expect(definition.workflow_trigger_kind).to eq("merge_train")
    expect(definition.scope_for(job: second, artifacts: { "merge_train_id" => train.id })).to have_attributes(type: "repository", id: repository.id)
    expect(definition.members_for(job: second, artifacts: { "merge_train_id" => train.id })).to eq([ first, second ])
  end

  it "resolves merge train validation members from the prefetch artifact through the definition" do
    user = Factories.user
    repository = Factories.repository(user: user)
    epic = Factories.epic(user: user, repository: repository)
    first = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 101)
    second = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 102)

    definition = described_class.for("merge_train_validation")

    expect(definition.members_for(job: second, artifacts: { "prefetch_merge_train_member_job_ids" => [ first.id, second.id ] })).to eq([ first, second ])
  end

  it "resolves job bundle validation members from the prefetch artifact through the definition" do
    user = Factories.user
    repository = Factories.repository(user: user)
    first = Factories.job_record(user: user, repository: repository, issue_number: 101)
    second = Factories.job_record(user: user, repository: repository, issue_number: 102)

    definition = described_class.for("job_bundle_validation")

    expect(definition.label).to eq("Job bundle validation")
    expect(definition.workflow_trigger_kind).to eq("merge_train_validation")
    expect(definition.scope_for(job: second, artifacts: {})).to have_attributes(type: "repository", id: repository.id)
    expect(definition.members_for(job: second, artifacts: { "prefetch_merge_train_member_job_ids" => [ first.id, second.id ] })).to eq([ first, second ])
  end

  it "declares landing locks for landing definitions" do
    job = Factories.job_record
    landing_kinds = described_class.landing_lock_kinds

    landing_kinds.each do |kind|
      definition = described_class.for(kind)
      keys = definition.lock_keys_for(job: job, member_jobs: [ job ], artifacts: {})

      if definition.child?
        expect(keys).not_to include("landing:repository:#{job.repository_id}")
      else
        expect(keys).to include("landing:repository:#{job.repository_id}")
      end
    end
  end

  it "marks infrastructure workflows explicitly" do
    expect(described_class.for("main_grader")).to be_infrastructure
    expect(described_class.for("agent_insight")).to be_infrastructure
  end

  it "declares workflow definitions that own their Job lifecycle" do
    lifecycle_owner_kinds = described_class.registry.values
      .map(&:new)
      .select(&:manages_own_job_lifecycle?)
      .map(&:kind)

    expect(lifecycle_owner_kinds).to contain_exactly(
      "main_grader",
      "agent_insight",
      "main_branch_repair",
      "landing_validation",
      "merge_train_validation",
      "job_bundle_validation",
      "promotion",
      "hotfix_sync"
    )
  end
end
