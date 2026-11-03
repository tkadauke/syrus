require "rails_helper"

RSpec.describe Permissions::JobLifecycle do
  let(:chat_entries) { McpToolRegistry.entries(surface: :chat).index_by(&:tool_name) }

  it "maps every lifecycle tool to an explicit, non-legacy chat registration" do
    described_class.tool_names.each do |tool_name|
      entry = chat_entries.fetch(tool_name)

      expect(entry).to have_attributes(explicit_descriptor: true, compatibility_descriptor: false)
      expect(entry.descriptor.operation).to match(%r{\Asyrus\.(jobs|epics|landing_queue)/[a-z_]+@v1\z})
      expect(entry.descriptor.classify({})).to include(confidence: :certain)
    end
  end

  it "covers every registered landing-queue tool, preserving admin-only registration" do
    landing = chat_entries.values.select { |entry| entry.tool_name.include?("landing") }

    expect(landing.map(&:tool_name)).to include("wake_landing_queue", "pause_landing_queue", "resume_landing_queue")
    landing.each do |entry|
      expect(described_class).to be_covers(entry.tool_name)
      expect(entry.descriptor.capability).to eq("syrus.landing_queue@v1")
      expect(entry).to have_attributes(explicit_descriptor: true, compatibility_descriptor: false)
    end
    expect(chat_entries.fetch("wake_landing_queue").admin_only).to be(true)
  end

  it "uses unique operations under the stable capability families" do
    descriptors = described_class.tool_names.map { |name| described_class.descriptor_for(name) }

    expect(descriptors.map(&:operation).uniq.size).to eq(descriptors.size)
    expect(descriptors.map(&:capability).uniq).to contain_exactly("syrus.jobs@v1", "syrus.epics@v1", "syrus.landing_queue@v1")
  end

  it "keeps proposals as a separate lifecycle outside the Job and Epic capabilities" do
    proposal_tools = %w[propose_job propose_epic propose_epic_with_jobs]

    proposal_tools.each do |tool_name|
      expect(described_class).not_to be_covers(tool_name)
      expect(chat_entries.fetch(tool_name).descriptor.capability).not_to match(/\Asyrus\.(jobs|epics)@/)
    end
  end

  it "classifies and fingerprints single and bulk invocations identically" do
    descriptor = described_class.descriptor_for("approve_job")

    expect(descriptor.classify(job_id: 7)).to eq(descriptor.classify(job_ids: [ 7, 8, 9 ]))
    expect(descriptor.normalize_fingerprint(job_id: 7)).to eq(descriptor.normalize_fingerprint(job_ids: [ 7 ]))
    expect(descriptor.normalize_fingerprint(job_ids: [ 9, 7, 7 ])).to eq(descriptor.normalize_fingerprint(job_ids: [ "7", 9 ]))
    expect(descriptor.normalize_fingerprint(job_id: 7)).not_to eq(descriptor.normalize_fingerprint(job_id: 8))
  end

  it "defaults lifecycle mutations to ask and raises no registry findings for lifecycle tools" do
    expect(chat_entries.fetch("cancel_job").descriptor.defaults.values.uniq).to eq([ :ask ])

    findings = Permissions::CapabilityRegistryValidator.for_application.findings
    lifecycle = findings.select do |finding|
      finding.registrations.any? { |registration| described_class.covers?(registration.tool_name) }
    end
    expect(lifecycle).to be_empty
  end
end
