# frozen_string_literal: true

require "open3"
require "tmpdir"
require "spec_helper"

RSpec.describe "macOS worker uninstaller" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/uninstall-macos-worker") }

  # Stubs the macOS tools the uninstaller asks about the host: launchd
  # reports the worker services loaded (or not), dscl the service account.
  def run_uninstaller(dir, *args, services_loaded: false)
    shim_dir = File.join(dir, "bin")
    FileUtils.mkdir_p(shim_dir)
    File.write(File.join(shim_dir, "uname"), "#!/usr/bin/env sh\nprintf 'Darwin\\n'\n")
    File.write(File.join(shim_dir, "launchctl"), "#!/usr/bin/env sh\n[ \"$1\" = print ] && exit #{services_loaded ? 0 : 1}\nexit 0\n")
    File.write(File.join(shim_dir, "dscl"), "#!/usr/bin/env sh\nexit 0\n")
    FileUtils.chmod(0o755, Dir[File.join(shim_dir, "*")])

    Open3.capture3(
      { "PATH" => "#{shim_dir}:/usr/bin:/bin" },
      "bash", script, "--dry-run", "--install-root", File.join(dir, "opt-syrus"), "--data-root", File.join(dir, "data"), *args,
      unsetenv_others: true
    )
  end

  it "removes the install but keeps what the installer cannot recreate, by default" do
    Dir.mktmpdir do |dir|
      stdout, stderr, status = run_uninstaller(dir, services_loaded: true)

      expect(status).to be_success, stderr
      expect(stdout).to include("+ launchctl bootout system/com.syrus.worker")
      expect(stdout).to include("+ launchctl bootout system/com.syrus.updater")
      expect(stdout).to include("+ rm -rf #{dir}/opt-syrus /usr/local/libexec/syrus")
      expect(stdout).not_to include("launchctl kill")
      expect(stdout).not_to include("rm -rf #{dir}/data")
      expect(stdout).not_to include("dscl . -delete")
      expect(stdout).to include("Kept: /etc/syrus/worker.env /etc/syrus/macos-worker-update-public.pem #{dir}/data /var/log/syrus the syrus-worker account")
      expect(stdout).not_to include("homebrew")
    end
  end

  it "leaves nothing of the worker behind with --all" do
    Dir.mktmpdir do |dir|
      stdout, stderr, status = run_uninstaller(dir, "--all")

      expect(status).to be_success, stderr
      expect(stdout).to include("+ rm -rf #{dir}/data /var/log/syrus")
      expect(stdout).to include("+ dscl . -delete /Users/syrus-worker")
      expect(stdout).to include("+ dscl . -delete /Groups/syrus-worker")
      expect(stdout).to include("+ rm -f /etc/syrus/worker.env /etc/syrus/macos-worker-update-public.pem /etc/syrus/tunnel.kubeconfig")
      expect(stdout).not_to include("Kept:")
    end
  end

  it "kills the worker instead of letting it drain with --force" do
    Dir.mktmpdir do |dir|
      stdout, stderr, status = run_uninstaller(dir, "--force", services_loaded: true)

      expect(status).to be_success, stderr
      kill = stdout.index("+ launchctl kill SIGKILL system/com.syrus.worker")
      expect(kill).not_to be_nil
      expect(kill).to be < stdout.index("+ launchctl bootout system/com.syrus.worker")
    end
  end

  it "refuses to remove a system directory given as a root" do
    Dir.mktmpdir do |dir|
      _stdout, stderr, status = run_uninstaller(dir, "--install-root", "/opt")

      expect(status.exitstatus).to eq(2)
      expect(stderr).to include("refusing to remove /opt")
    end
  end
end
