require "rails_helper"

RSpec.describe Syrus::Plugin::RuntimeSessionProvider do
  let(:incomplete_class) do
    Class.new { include Syrus::Plugin::RuntimeSessionProvider }
  end

  describe "class-level interface defaults" do
    it "requires provider_key" do
      expect { incomplete_class.provider_key }.to raise_error(NotImplementedError)
    end

    it "requires display_name" do
      expect { incomplete_class.display_name }.to raise_error(NotImplementedError)
    end

    it "requires detect" do
      expect { incomplete_class.detect(nil, {}) }.to raise_error(NotImplementedError)
    end

    it "requires capabilities" do
      expect { incomplete_class.capabilities(nil, {}) }.to raise_error(NotImplementedError)
    end
  end

  describe "instance-level interface defaults" do
    subject(:instance) { incomplete_class.new }

    it "requires start_session" do
      expect { instance.start_session("workspace-ref", {}) }.to raise_error(NotImplementedError)
    end

    it "requires build_or_reload" do
      expect { instance.build_or_reload("session-1", {}) }.to raise_error(NotImplementedError)
    end

    it "requires launch" do
      expect { instance.launch("session-1", {}) }.to raise_error(NotImplementedError)
    end

    it "requires snapshot" do
      expect { instance.snapshot("session-1", {}) }.to raise_error(NotImplementedError)
    end

    it "requires inspect, callable with no arguments" do
      expect { instance.inspect }.to raise_error(NotImplementedError)
    end

    it "requires input" do
      expect { instance.input("session-1", {}) }.to raise_error(NotImplementedError)
    end

    it "requires logs" do
      expect { instance.logs("session-1", nil, {}) }.to raise_error(NotImplementedError)
    end

    it "requires stop_session" do
      expect { instance.stop_session("session-1") }.to raise_error(NotImplementedError)
    end
  end

  describe "a concrete provider" do
    let(:concrete_class) do
      Class.new do
        include Syrus::Plugin::RuntimeSessionProvider

        def self.provider_key = "stub"
        def self.display_name = "Stub"
        def self.detect(_repository, _config) = true
        def self.capabilities(_repository, _config) = { stream: "none" }

        def start_session(workspace_ref, _config) = { workspace_ref: workspace_ref }
        def build_or_reload(_session_id, _options) = true
        def launch(_session_id, _options) = true
        def snapshot(_session_id, _options) = nil
        def inspect(_session_id = nil, _options = nil) = {}
        def input(_session_id, _event) = true
        def logs(_session_id, _cursor, _options) = []
        def stop_session(_session_id) = true
      end
    end

    it "can be looked up by provider_key and display_name" do
      expect(concrete_class.provider_key).to eq("stub")
      expect(concrete_class.display_name).to eq("Stub")
    end

    it "detects and reports capabilities at the class level" do
      expect(concrete_class.detect(double(:repository), {})).to be true
      expect(concrete_class.capabilities(double(:repository), {})).to eq(stream: "none")
    end

    it "implements the instance lifecycle without raising" do
      instance = concrete_class.new
      expect(instance.start_session("workspace-ref", {})).to eq(workspace_ref: "workspace-ref")
      expect(instance.stop_session("session-1")).to be true
    end
  end
end
