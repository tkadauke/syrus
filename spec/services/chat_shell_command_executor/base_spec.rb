require "rails_helper"

RSpec.describe ChatShellCommandExecutor::Base do
  describe ".for" do
    it "resolves \"coding\" to ChatShellCommandExecutor::Coding" do
      expect(described_class.for("coding")).to be_a(ChatShellCommandExecutor::Coding)
    end

    it "resolves \"local\" to ChatShellCommandExecutor::Local" do
      expect(described_class.for("local")).to be_a(ChatShellCommandExecutor::Local)
    end

    it "raises for an unsupported mode" do
      expect { described_class.for("planning") }.to raise_error(ArgumentError, /planning/)
    end
  end
end
