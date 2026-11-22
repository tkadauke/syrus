require "rails_helper"

# An existing Workflow must keep answering questions about its definition after
# the plugin that owns its kind is disabled or turns unhealthy, so it can be
# finished or cancelled; launching new work must still refuse the kind (NY14).
RSpec.describe WorkDefinitions, ".for_existing" do
  it "answers with the neutral Unavailable definition for a kind no installed plugin provides" do
    definition = described_class.for_existing("uninstalled_plugin_kind")

    expect(definition).to be_a(described_class::Unavailable)
    expect(definition.manages_own_job_lifecycle?).to be(false)
  end

  it "never offers Unavailable to anything that launches work" do
    expect(described_class.registry.values).not_to include(described_class::Unavailable)
    expect { described_class.for("unavailable") }.to raise_error(described_class::UnknownKind)
  end

  it "answers exactly like .for while the kind is registered" do
    expect(described_class.for_existing("initial").class).to eq(described_class.for("initial").class)
  end
end
