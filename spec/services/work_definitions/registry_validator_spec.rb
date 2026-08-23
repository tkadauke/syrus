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
end
