require "rails_helper"

RSpec.describe WorkDefinitions::RegistryValidator do
  it "keeps workflow trigger kinds and WorkDefinitions in sync" do
    errors = described_class.call

    expect(errors).to be_empty
  end

  it "allows WorkDefinitions to reuse an existing workflow template trigger for specialized unit kinds" do
    checkpoint = WorkDefinitions.for("checkpoint_resume")

    expect(checkpoint.workflow_trigger_kind).to eq("retry")
    expect(checkpoint.workflow_template).to eq(Workflows::CheckpointResume)
  end

  it "reports a first-class workflow trigger kind without a matching WorkDefinition" do
    entry = Workflow::TriggerKind::Entry.new(
      kind: "spec_missing_definition",
      template: "Initial",
      label: "Spec missing definition",
      style: "bg-gray-100",
      retry_label: "Retry failed step",
      feedback_kind: nil,
      runtime_role: "first_class"
    )
    stub_const("Workflow::TriggerKind::ENTRIES", Workflow::TriggerKind::ENTRIES + [ entry ])

    errors = described_class.call

    expect(errors.map(&:code)).to include("missing_definition")
    expect(errors.map(&:message)).to include(/spec_missing_definition/)
  end

  it "is exposed through WorkDefinitions.validate_registry!" do
    expect { WorkDefinitions.validate_registry! }.not_to raise_error
  end

  it "declares approval and epic-readiness intent gates for landing definitions" do
    expect(WorkDefinitions.for("auto_merge").intent_gates).to include(WorkIntents::Gates::Approval)
    expect(WorkDefinitions.for("external_pr_merge").intent_gates).to include(WorkIntents::Gates::Approval)
    expect(WorkDefinitions.for("merge_train").intent_gates).to include(
      WorkIntents::Gates::Approval,
      WorkIntents::Gates::EpicReadiness
    )
  end

  it "requires landing-lock definitions to have a feature-gated path owner" do
    stub_const(
      "WorkUnits::PathOwnership::LANDING_PATHS",
      WorkUnits::PathOwnership::LANDING_PATHS - %w[auto_merge]
    )

    errors = described_class.call

    expect(errors.map(&:code)).to include("missing_landing_path")
    expect(errors.map(&:message)).to include(/auto_merge/)
  end

  it "requires landing prefetch definitions to declare a validation child" do
    allow(WorkDefinitions).to receive(:landing_validation_child_kind_for).and_call_original
    allow(WorkDefinitions).to receive(:landing_validation_child_kind_for).with("auto_merge").and_return(nil)

    errors = described_class.call

    expect(errors.map(&:code)).to include("missing_landing_validation_child")
    expect(errors.map(&:message)).to include(/auto_merge/)
  end

  it "requires landing validation children to point at landing prefetch parents" do
    allow_any_instance_of(WorkDefinitions::LandingValidation).to receive(:parent_kind).and_return("retry")

    errors = described_class.call

    expect(errors.map(&:code)).to include("invalid_landing_validation_parent")
    expect(errors.map(&:message)).to include(/landing_validation/)
  end

  it "requires landing-lock constants to name existing definitions" do
    stub_const(
      "WorkDefinitions::Base::LANDING_LOCK_KINDS",
      WorkDefinitions::Base::LANDING_LOCK_KINDS + %w[missing_landing_kind]
    )

    errors = described_class.call

    expect(errors.map(&:code)).to include("unknown_landing_lock_kind")
    expect(errors.map(&:message)).to include(/missing_landing_kind/)
  end
end
