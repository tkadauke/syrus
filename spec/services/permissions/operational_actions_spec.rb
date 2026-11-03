require "rails_helper"

RSpec.describe Permissions::OperationalActions do
  let(:chat_entries) { McpToolRegistry.entries(surface: :chat).index_by(&:tool_name) }

  it "maps every operational tool to an explicit, non-legacy chat registration" do
    described_class.tool_names.each do |tool_name|
      entry = chat_entries.fetch(tool_name)

      expect(entry).to have_attributes(explicit_descriptor: true, compatibility_descriptor: false)
      expect(entry.descriptor.operation).to match(%r{\Asyrus\.(admin_repair|operations|delivery)/[a-z_]+@v1\z})
      expect(entry.descriptor.classify({})).to include(confidence: :certain)
    end
  end

  it "preserves admin-only and feature-flag registration metadata" do
    expect(chat_entries.fetch("force_fail_job").admin_only).to be(true)
    expect(chat_entries.fetch("emergency_land")).to have_attributes(feature_flag: :emergency_land, required_roles: [ AgentRole::CHAT_CODING ])
    expect(chat_entries.fetch("emergency_land").descriptor.requestable_roles).to eq([ AgentRole::CHAT_CODING.to_s ])
  end

  it "uses unique operations" do
    operations = described_class.tool_names.map { |name| described_class.descriptor_for(name).operation }

    expect(operations.uniq.size).to eq(operations.size)
  end

  it "limits every operation to exact-invocation authority defaulting to ask" do
    described_class.tool_names.each do |tool_name|
      descriptor = chat_entries.fetch(tool_name).descriptor

      expect(descriptor.maximum_autonomy).to eq(:invocation)
      expect(descriptor.authority_durations).to eq([ :invocation ])
      expect(descriptor.defaults.values.uniq).to eq([ :ask ])
    end
  end

  it "classifies emergency landing as critical and irreversible" do
    classification = chat_entries.fetch("emergency_land").descriptor.classify({})

    expect(classification).to include(risk: :critical)
    expect(classification[:effects]).to include(:irreversible, :destructive, :external_write)
  end

  it "fingerprints exact arguments and collapses single and bulk Job targets" do
    descriptor = described_class.descriptor_for("force_fail_job")

    expect(descriptor.normalize_fingerprint(job_id: 7, reason: "x")).to eq(descriptor.normalize_fingerprint(job_ids: [ "7" ], reason: "x"))
    expect(descriptor.normalize_fingerprint(job_id: 7, reason: "x")).not_to eq(descriptor.normalize_fingerprint(job_id: 7, reason: "y"))
  end

  it "does not overlap with the Job lifecycle tools and raises no registry findings" do
    expect(described_class.tool_names & Permissions::JobLifecycle.tool_names).to be_empty

    findings = Permissions::CapabilityRegistryValidator.for_application.findings
    mine = findings.select { |f| f.registrations.any? { |r| described_class.covers?(r.tool_name) } }
    expect(mine).to be_empty
  end
end
