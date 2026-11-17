require "rails_helper"

RSpec.describe RetentionPolicySetting do
  let(:definition) { RetentionPolicyRegistry.fetch(:notification) }

  it "uses the registry default without creating a row" do
    expect(definition.retention_value).to eq(30)
    expect(described_class.find_by(retention_key: "notification")).to be_nil
  end

  it "resolves persisted and default settings for many definitions in one query" do
    run_diagnostic = RetentionPolicyRegistry.fetch(:run_diagnostic)
    described_class.write!(run_diagnostic, archive_before_delete: true)
    allow(described_class).to receive(:where).and_call_original

    settings = described_class.for_definitions([ definition, run_diagnostic ])

    expect(described_class).to have_received(:where).once
    expect(settings.fetch("notification")).to be_new_record
    expect(settings.fetch("notification").archive_before_delete).to be_nil
    expect(settings.fetch("run_diagnostic").archive_before_delete?).to be(true)
  end

  it "stores finite durations as canonical seconds and infinite retention as nil" do
    described_class.write!(definition, retention_value: 12)
    expect(described_class.find_by!(retention_key: "notification").retention_seconds).to eq(12.days.to_i)

    described_class.write!(definition, retention_value: 0)
    expect(described_class.find_by!(retention_key: "notification").retention_seconds).to be_nil
    expect(definition.retention_value).to eq(0)
  end

  it "keeps archive state nil for a policy that does not support archiving" do
    described_class.write!(definition, retention_value: 10, archive_before_delete: true)

    expect(definition.setting.archive_before_delete).to be_nil
  end

  it "allows an inert row whose plugin policy is no longer registered" do
    row = described_class.create!(retention_key: "removed_plugin_policy", retention_seconds: 1.day.to_i)

    expect(row.reload.retention_seconds).to eq(1.day.to_i)
  end
end
