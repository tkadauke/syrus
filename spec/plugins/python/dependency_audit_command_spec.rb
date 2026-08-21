require "rails_helper"
require "tmpdir"

RSpec.describe Python::DependencyAuditCommand do
  describe ".lockfiles" do
    it "returns the true Python lockfiles, excluding bare pyproject.toml" do
      expect(described_class.lockfiles).to contain_exactly("uv.lock", "poetry.lock", "requirements.txt")
    end
  end

  describe ".audit_command" do
    it "returns nil when no lockfile is present" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "pyproject.toml"), "")
        expect(described_class.audit_command(workspace_path: dir)).to be_nil
      end
    end

    it "returns pip-audit when uv.lock is present" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "uv.lock"), "")
        expect(described_class.audit_command(workspace_path: dir)).to eq("pip-audit")
      end
    end

    it "returns pip-audit when requirements.txt is present" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "requirements.txt"), "")
        expect(described_class.audit_command(workspace_path: dir)).to eq("pip-audit")
      end
    end
  end
end
