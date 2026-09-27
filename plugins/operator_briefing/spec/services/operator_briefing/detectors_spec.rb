require "rails_helper"

RSpec.describe "operator briefing notable-change detectors" do
  let(:job) { Factories.job_with_run }
  let(:workflow) { job.workflows.first }

  it "detects deterministic cognitive-debt signals from a changed-file list" do
    changed_files = [
      "Gemfile.lock",
      "db/migrate/20260927000000_add_widgets.rb",
      "config/routes.rb",
      "app/policies/widget_policy.rb"
    ]

    facts = [
      OperatorBriefing::Detectors::DependencyChanges,
      OperatorBriefing::Detectors::SchemaChanges,
      OperatorBriefing::Detectors::PublicApiChanges,
      OperatorBriefing::Detectors::SecuritySensitivePaths
    ].flat_map do |detector|
      detector.detect(
        workflow: workflow,
        diff: "",
        changed_files: changed_files,
        name_status: [],
        workspace_path: Rails.root
      )
    end

    expect(facts.map(&:key)).to contain_exactly(
      "dependencies:lockfiles_changed",
      "schema:schema_or_migration_changed",
      "public_api:public_interface_changed",
      "security_sensitive_paths:security_sensitive_paths_changed"
    )
  end

  it "detects deleted or weakened tests" do
    facts = OperatorBriefing::Detectors::TestCoverageChanges.detect(
      workflow: workflow,
      diff: "-  pending \"covers the edge case\"\n",
      changed_files: [ "spec/models/widget_spec.rb" ],
      name_status: [ [ "D", "spec/models/old_widget_spec.rb" ] ],
      workspace_path: Rails.root
    )

    expect(facts.first).to have_attributes(
      key: "test_coverage:tests_removed_or_weakened",
      severity: "attention_debt"
    )
  end
end
