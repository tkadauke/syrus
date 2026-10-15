require "spec_helper"
require "open3"
require "tmpdir"
require "fileutils"

RSpec.describe "bin/compose-up" do
  let(:root) { File.expand_path("../..", __dir__) }

  it "keeps .env private and defaults the port when it is absent" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      FileUtils.cp(File.join(root, "bin/compose-up"), File.join(dir, "bin/compose-up"))
      FileUtils.cp(File.join(root, "compose.env.example"), dir)
      File.write(File.join(dir, "docker-compose.yml"), "")
      File.write(File.join(dir, "docker-compose.build.yml"), "")
      File.write(File.join(dir, "bin/docker-image-lib"), <<~BASH)
        syrus_require_docker_daemon() { return 0; }
        syrus_disable_buildx_attestations() { :; }
        syrus_build_local_base_image() { :; }
      BASH

      stub_dir = File.join(dir, "stubs")
      FileUtils.mkdir_p(stub_dir)
      File.write(File.join(stub_dir, "docker"), <<~BASH)
        #!/usr/bin/env bash
        if [ "$1 $2" = "compose version" ]; then exit 0; fi
        if [ "$1 $2" = "volume inspect" ]; then exit 1; fi
        exit 0
      BASH
      FileUtils.chmod(0o755, File.join(stub_dir, "docker"))

      stdout, stderr, status = Open3.capture3(
        { "PATH" => "#{stub_dir}:#{ENV.fetch("PATH")}" },
        "bash", File.join(dir, "bin/compose-up"),
        chdir: dir
      )

      expect(status).to be_success, stderr
      expect(stdout).to include("http://localhost:3000")
      expect(File.stat(File.join(dir, ".env")).mode & 0o777).to eq(0o600)

      File.write(File.join(dir, ".env"), "SECRET_KEY_BASE=existing\n")
      File.chmod(0o644, File.join(dir, ".env"))
      stdout, stderr, status = Open3.capture3(
        { "PATH" => "#{stub_dir}:#{ENV.fetch("PATH")}" },
        "bash", File.join(dir, "bin/compose-up"),
        chdir: dir
      )

      expect(status).to be_success, stderr
      expect(stdout).to include("http://localhost:3000")
      expect(File.stat(File.join(dir, ".env")).mode & 0o777).to eq(0o600)
    end
  end
end
