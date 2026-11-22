require "rails_helper"

# A trigger kind that owns its Job's lifecycle is skipped by generic
# propagation (Workflows::JobLifecyclePropagation#fail! and #cancel!). If that
# kind also lifts its Job to :running on start, its own after_fail and
# after_cancel hooks are the only thing that can move the Job off :running
# again -- a kind relying on the no-op Workflows::Base hooks strands the Job
# with nothing working on it. Landing and infrastructure kinds never lift the
# Job, so they are exempt. See formal/SyrusModel/RunningHasWork.lean.
RSpec.describe "lifecycle-owning trigger kinds settle the Job they lift" do
  # external_pr_ingest settles failure in after_fail and is not skipped by
  # generic cancel!, so only its failure hook is its own.
  GENERIC_CANCEL_KINDS = %w[external_pr_ingest].freeze

  lifting_owners = Workflow::TriggerKind.values.select do |kind|
    next false unless Workflow::TriggerKind.owns_job_lifecycle?(kind)

    workflow = Workflow.new(trigger_kind: kind)
    !workflow.landing_workflow? && !workflow.infrastructure_workflow?
  end

  it "covers the kinds known to lift their Job" do
    expect(lifting_owners).to include("coding_handoff", "local_mode_handoff", "external_pr_ingest")
  end

  lifting_owners.each do |kind|
    it "#{kind} defines its own after_fail#{' and after_cancel' unless GENERIC_CANCEL_KINDS.include?(kind)}" do
      klass = Workflows.for(trigger_kind: kind)
      hooks = %i[after_fail]
      hooks << :after_cancel unless GENERIC_CANCEL_KINDS.include?(kind)

      hooks.each do |hook|
        expect(klass.method(hook).owner).not_to eq(Workflows::Base.singleton_class),
          "#{kind} owns its Job lifecycle and lifts the Job on start, but inherits the no-op #{hook}"
      end
    end
  end
end
