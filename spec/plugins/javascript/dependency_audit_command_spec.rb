require "rails_helper"
require "tmpdir"

RSpec.describe JavaScript::DependencyAuditCommand do
  describe ".lockfiles" do
    it "returns the three true lockfile names, excluding package.json" do
      expect(described_class.lockfiles).to contain_exactly(
        "yarn.lock", "pnpm-lock.yaml", "package-lock.json"
      )
    end
  end

  describe ".audit_command" do
    it "returns nil when no lockfile is present" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "package.json"), "{}")
        expect(described_class.audit_command(workspace_path: dir)).to be_nil
      end
    end

    it "prefers yarn.lock when present" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "yarn.lock"), "")
        File.write(File.join(dir, "package-lock.json"), "{}")
        expect(described_class.audit_command(workspace_path: dir)).to eq("yarn audit --json")
      end
    end

    it "uses pnpm audit when only pnpm-lock.yaml is present" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "pnpm-lock.yaml"), "")
        expect(described_class.audit_command(workspace_path: dir)).to eq("pnpm audit --json")
      end
    end

    it "uses npm audit when only package-lock.json is present" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "package-lock.json"), "{}")
        expect(described_class.audit_command(workspace_path: dir)).to eq("npm audit --json")
      end
    end
  end
end
