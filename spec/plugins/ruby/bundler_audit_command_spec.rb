require "rails_helper"
require "tmpdir"

RSpec.describe Ruby::BundlerAuditCommand do
  describe ".lockfiles" do
    it "returns Gemfile.lock" do
      expect(described_class.lockfiles).to eq([ "Gemfile.lock" ])
    end
  end

  describe ".audit_command" do
    it "returns nil when Gemfile.lock is not present" do
      Dir.mktmpdir do |dir|
        expect(described_class.audit_command(workspace_path: dir)).to be_nil
      end
    end

    it "returns the bundler-audit command when Gemfile.lock is present" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Gemfile.lock"), "")
        expect(described_class.audit_command(workspace_path: dir)).to eq("bundle-audit check --update")
      end
    end
  end
end
