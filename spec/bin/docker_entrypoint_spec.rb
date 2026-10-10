require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe "bin/docker-entrypoint" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:entrypoint) { File.join(root, "bin/docker-entrypoint") }

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

      _stdout, stderr, status = Open3.capture3(entrypoint, "./bin/jobs", chdir: dir)

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

      _stdout, stderr, status = Open3.capture3(entrypoint, "./bin/jobs", chdir: dir)

      expect(status).to be_success, stderr
      expect(File.readlines(File.join(dir, "rails.calls"), chomp: true)).to eq([
        "db:abort_if_pending_migrations",
        "syrus:prepare_search"
      ])
    end
  end
end
