require "rails_helper"

RSpec.describe SyrusBrowser::Configuration do
  describe ".endpoint" do
    it "delegates to PluginRuntime::Services for the browser service name" do
      allow(PluginRuntime::Services).to receive(:endpoint_for).with("browser").and_return("http://browser-service:8080")

      expect(described_class.endpoint).to eq("http://browser-service:8080")
    end

    it "answers nil when Plugin Runtime has no browser service registered" do
      allow(PluginRuntime::Services).to receive(:endpoint_for).with("browser").and_return(nil)

      expect(described_class.endpoint).to be_nil
    end
  end
end
