require "rails_helper"
require "tmpdir"

RSpec.describe Go::DependencyAuditCommand do
  describe ".lockfiles" do
    it "returns go.sum" do
      expect(described_class.lockfiles).to eq([ "go.sum" ])
    end
  end

  describe ".audit_command" do
    it "returns nil when go.sum is not present" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "go.mod"), "module example")
        expect(described_class.audit_command(workspace_path: dir)).to be_nil
      end
    end

    it "returns govulncheck when go.sum is present" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "go.sum"), "")
        expect(described_class.audit_command(workspace_path: dir)).to eq("govulncheck ./...")
      end
    end
  end
end
