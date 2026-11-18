require "rails_helper"

RSpec.describe Syrus::Host do
  around do |example|
    original = described_class.apis.dup
    described_class.apis.clear
    example.run
  ensure
    described_class.apis.replace(original)
  end

  it "exposes the declaration file through its Zeitwerk constant" do
    expect(described_class::PluginApis::INTERFACES).to include("McpToolSet")
  end

  it "registers a public API contract" do
    api = described_class.api(
      "Syrus::Host::Example",
      since: "1.2.3",
      summary: "A stable example contract.",
      members: %i[call status]
    )

    expect(api).to have_attributes(
      name: "Syrus::Host::Example",
      since: "1.2.3",
      summary: "A stable example contract.",
      members: %w[call status]
    )
    expect(described_class.public?("Syrus::Host::Example::Result")).to be(true)
  end

  it "does not make undeclared constants public by namespace alone" do
    expect(described_class.public?("Syrus::Host::Undeclared")).to be(false)
  end

  it "rejects declarations outside the public host namespace" do
    expect do
      described_class.api("Syrus::Plugin::Callbacks", since: "1.2.3", summary: "Legacy.", members: [])
    end.to raise_error(ArgumentError, /must live under Syrus::Host/)
  end

  it "rejects an invalid release version" do
    expect do
      described_class.api("Syrus::Host::Example", since: "next", summary: "Example.", members: [])
    end.to raise_error(ArgumentError, /invalid release version/)
  end

  it "requires a summary" do
    expect do
      described_class.api("Syrus::Host::Example", since: "1.2.3", summary: "", members: [])
    end.to raise_error(ArgumentError, /summary is required/)
  end

  it "rejects duplicate API names" do
    2.times do |index|
      if index.zero?
        described_class.api("Syrus::Host::Example", since: "1.2.3", summary: "Example.", members: [])
      else
        expect do
          described_class.api("Syrus::Host::Example", since: "1.2.4", summary: "Duplicate.", members: [])
        end.to raise_error(ArgumentError, /duplicate plugin host API/)
      end
    end
  end
end
