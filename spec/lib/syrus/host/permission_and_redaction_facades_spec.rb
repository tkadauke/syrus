require "rails_helper"

RSpec.describe "Syrus::Host permission presentation and redaction facades" do
  ALIASED_PERMISSION_REDACTION = {
    CapabilityPresentation: Permissions::CapabilityPresentation,
    CommandRedactor: ::CommandRedactor,
    McpPagination: Mcp::Pagination,
    CredentialProbe: ::CredentialProbe,
    ToolPayloadRedactor: ::ToolPayloadRedactor,
    EvidenceRedactor: Mcp::Tools::EvidenceRedactor,
    CapabilityDescriptor: Permissions::CapabilityDescriptorAdapter
  }.freeze

  ALIASED_PERMISSION_REDACTION.each do |name, core|
    it "aliases Syrus::Host::#{name} to its core value and declares a public contract" do
      expect(Syrus::Host.const_get(name)).to equal(core)
      expect(Syrus::Host.public?("Syrus::Host::#{name}")).to be(true)
    end

    it "only lists members that exist on Syrus::Host::#{name}" do
      api = Syrus::Host.apis.find { |entry| entry.name == "Syrus::Host::#{name}" }
      expect(api.members).not_to be_empty
      api.members.each do |member|
        exists = member.match?(/\A[A-Z]/) ? core.const_defined?(member) : (core.respond_to?(member) || core.method_defined?(member))
        expect(exists).to be_truthy, "#{name}.#{member}"
      end
    end
  end

  it "keeps the authority durations identical to the core descriptor's" do
    expect(Syrus::Host::CapabilityDescriptor::AUTHORITY_DURATIONS).to eq(Permissions::CapabilityDescriptor::AUTHORITY_DURATIONS)
  end

  it "redacts through the public facades exactly as core does" do
    text = "git clone https://x-access-token:abc123@github.com/o/r.git"
    expect(Syrus::Host::CommandRedactor.redact(text)).to eq(CommandRedactor.redact(text))
    expect(Syrus::Host::CommandRedactor.redact(text)).not_to include("abc123")
    expect(Syrus::Host::ToolPayloadRedactor.redact("password" => "hunter2-long-value")).to eq(ToolPayloadRedactor.redact("password" => "hunter2-long-value"))
    expect(Syrus::Host::McpPagination.normalize_page("0")).to eq(1)
  end

  it "builds presentation metadata through the facade" do
    presentation = Syrus::Host::CapabilityPresentation.for(capability: "k8s.observe@v1", operation: "k8s.pod/list@v1")
    expect(presentation.capability_name).to eq("K8s Observe")
    expect(presentation.operation_name).to eq("List")
  end

  it "no longer lists the promoted constants as legacy" do
    surface = Syrus::PluginHostSurface.new
    %w[CommandRedactor Mcp::Pagination CredentialProbe CredentialProbe::Result ToolPayloadRedactor Mcp::Tools::EvidenceRedactor
       Permissions::CapabilityPresentation Permissions::CapabilityDescriptor::AUTHORITY_DURATIONS].each do |name|
      expect(surface.lookup(name)).to be_nil, name
    end
  end
end
