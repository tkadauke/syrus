require "rails_helper"

RSpec.describe "plugin problem providers", :reset_plugin_registry do
  let(:provider) do
    Class.new do
      include Syrus::Plugin::ProblemProvider
      def self.problem_namespace = "synthetic"
      def self.problem_kinds
        [{ code: "synthetic.unavailable", scope: :external, retryable: true, default_remediation: :defer }]
      end
    end
  end
  let(:registry) do
    Syrus::KindRegistry.new(
      built_in: [], entry_class: Problem::Kind::Entry, provider_method: :problem_kinds, key: :code,
      extension_point: :problem_provider,
      validate_plugin_entry: ->(candidate, attrs) { attrs.fetch(:code).to_s.start_with?("#{candidate.problem_namespace}.") }
    )
  end

  it "accepts stable namespaced problem codes from a healthy provider" do
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:problem_provider).and_return([ provider ])
    expect(registry.send(:plugin_entries).first).to have_attributes(code: "synthetic.unavailable", scope: :external, retryable: true)
  end

  it "rejects problem codes outside the provider namespace" do
    allow(provider).to receive(:problem_kinds).and_return([{ code: "unscoped", scope: :run, retryable: false, default_remediation: :fail }])
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:problem_provider).and_return([ provider ])

    expect(registry.send(:plugin_entries)).to be_empty
  end
end
