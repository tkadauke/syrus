require "rails_helper"
require "open3"
require "tmpdir"

RSpec.describe "bin/disaster-recovery" do
  let(:script) { Rails.root.join("bin/disaster-recovery").to_s }
  let(:environment) { { "DATABASE_URL" => "invalid://must-not-connect", "SYRUS_RECOVERY_TOKEN_SECRET" => "secret" } }

  it "starts and reports usage without booting Rails" do
    output, status = Open3.capture2e({ "DATABASE_URL" => "invalid://must-not-connect" }, script)
    expect(status.exitstatus).to eq(64)
    expect(output).to include("bin/disaster-recovery COMMAND")
  end

  # NY22: an unknown blocks preflight, and only the flag named after it lets
  # it through.
  describe "preflight with unknown compatibility" do
    def bundle_in(root)
      bundle = Pathname.new(root).join("bundle").tap(&:mkpath)
      bundle.join("database.sqlite3").binwrite("database")
      checksums = bundle.join("checksums.sha256")
      checksums.write("#{Digest::SHA256.file(bundle.join('database.sqlite3')).hexdigest}  database.sqlite3\n")
      bundle.join("manifest.json").write(JSON.generate(
        manifest_version: "1.0", backup_id: "backup-1", completed_at: "2026-11-20T00:00:00Z",
        artifact: { format: "directory", checksum_path: "checksums.sha256" },
        checksum: Digest::SHA256.file(checksums).hexdigest, database: { adapter: "sqlite3" },
        source_application_version: "1.0.0"
      ))
      bundle
    end

    def preflight(root, *flags)
      Open3.capture2e(environment, script, "preflight", bundle_in(root).to_s, "--destination", root,
        "--installation-id", "install-a", "--database-adapter", "sqlite3", *flags)
    end

    it "blocks without the application version and passes with --allow-unknown-application-version" do
      Dir.mktmpdir do |root|
        output, status = preflight(root)
        expect(status.exitstatus).to eq(2)
        expect(JSON.parse(output)).to include("status" => "blocked")

        FileUtils.rm_rf(Pathname.new(root).join("bundle"))
        output, status = preflight(root, "--allow-unknown-encryption-fingerprints")
        expect(status.exitstatus).to eq(2)

        FileUtils.rm_rf(Pathname.new(root).join("bundle"))
        output, status = preflight(root, "--allow-unknown-application-version", "--allow-unknown-encryption-fingerprints")
        expect(status.exitstatus).to eq(0)
        report = JSON.parse(output)
        expect(report["status"]).to eq("ready")
        expect(report["checks"]).to include(include("name" => "application", "status" => "warn", "unknown" => "application-version"))
      end
    end
  end
end
