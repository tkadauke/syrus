require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe "bin/docker-entrypoint" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:entrypoint) { File.join(root, "bin/docker-entrypoint") }

  def entrypoint_env(dir)
    sync = File.join(dir, "plugin-sync")
    File.write(sync, "File.open('entrypoint.calls', 'a') { |file| file.puts('sync') }\n")
    { "SYRUS_PLUGIN_SYNC_EXECUTABLE" => sync, "BUNDLE_GEMFILE" => File.join(root, "Gemfile") }
  end

  it "refuses to start workers when migrations are pending" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      File.write(File.join(dir, "bin/rails"), <<~SH)
        #!/bin/sh
        echo "$*" >> rails.calls
        if [ "$*" = "db:abort_if_pending_migrations" ]; then
          echo "pending migrations" >&2
          exit 1
        fi
        exit 0
      SH
      File.write(File.join(dir, "bin/jobs"), <<~SH)
        #!/bin/sh
        echo jobs-started >> jobs.calls
      SH
      File.chmod(0o755, File.join(dir, "bin/rails"))
      File.chmod(0o755, File.join(dir, "bin/jobs"))

      _stdout, stderr, status = Open3.capture3(entrypoint_env(dir), entrypoint, "./bin/jobs", chdir: dir)

      expect(status).not_to be_success
      expect(stderr).to include("pending migrations")
      expect(File.read(File.join(dir, "rails.calls"))).to include("db:abort_if_pending_migrations")
      expect(File).not_to exist(File.join(dir, "jobs.calls"))
    end
  end

  it "checks migrations before worker search setup" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      File.write(File.join(dir, "bin/rails"), <<~SH)
        #!/bin/sh
        echo "$*" >> rails.calls
      SH
      File.write(File.join(dir, "bin/jobs"), <<~SH)
        #!/bin/sh
        echo jobs-started
      SH
      File.chmod(0o755, File.join(dir, "bin/rails"))
      File.chmod(0o755, File.join(dir, "bin/jobs"))

      _stdout, stderr, status = Open3.capture3(entrypoint_env(dir), entrypoint, "./bin/jobs", chdir: dir)

      expect(status).to be_success, stderr
      expect(File.readlines(File.join(dir, "rails.calls"), chomp: true)).to eq([
        "db:abort_if_pending_migrations",
        "syrus:prepare_search"
      ])
      expect(File.readlines(File.join(dir, "entrypoint.calls"), chomp: true)).to eq([ "sync" ])
    end
  end

  it "runs plugin sync before Rails for every command" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      File.write(File.join(dir, "bin/rails"), "#!/bin/sh\necho rails >> entrypoint.calls\n")
      File.chmod(0o755, File.join(dir, "bin/rails"))

      _stdout, stderr, status = Open3.capture3(entrypoint_env(dir), entrypoint, "./bin/rails", "server", chdir: dir)

      expect(status).to be_success, stderr
      expect(File.readlines(File.join(dir, "entrypoint.calls"), chomp: true)).to eq(%w[sync rails rails rails])
    end
  end
end
