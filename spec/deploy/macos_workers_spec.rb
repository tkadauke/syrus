# frozen_string_literal: true

require_relative "deploy_helper"
require "stringio"
require "tmpdir"

module DeploySpec
  # Answers curl by path and records every command, the way the real Shell
  # records a dry run's stream.
  class FakeMacShell
    attr_reader :commands
    attr_accessor :responses, :build_artifact

    def initialize(dry_run: false)
      @dry_run = dry_run
      @commands = []
      @responses = {}
      @build_artifact = nil
    end

    def dry_run? = @dry_run

    def stream_write(argv, env: {})
      commands << [ :stream, argv, env ]
      build_artifact&.call
      Deploy::Shell::Result.new(argv: argv, stdout: "", stderr: "", status: 0)
    end

    def write(argv) = answer(:write, argv)
    def read(argv) = answer(:read, argv)

    private

    def answer(mode, argv)
      commands << [ mode, argv ]
      path = argv.last.sub(%r{\Ahttps://[^/]+/api/v1/admin/macos_worker_releases}, "")
      # One [code, body] pair, or a list of them answered in order (the last repeats).
      entry = responses.fetch(path)
      code, body = entry.first.is_a?(Array) ? (entry.length > 1 ? entry.shift : entry.first) : entry
      Deploy::Shell::Result.new(argv: argv, stdout: "#{body}\n#{code}", stderr: "", status: 0)
    end
  end
end

RSpec.describe Deploy::MacosWorkers do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:reporter) { Deploy::Reporter.new(out: out, err: err) }
  let(:clock) { Deploy::Clock::Fake.new }
  let(:sha) { "50d35be290" }
  let(:dir) { Dir.mktmpdir("macos-workers-spec-") }
  let(:key_file) { File.join(dir, "signing.pem").tap { |path| File.write(path, "key") } }
  let(:repo) { Struct.new(:sha, :toplevel).new(sha, dir) }

  after { FileUtils.rm_rf(dir) }

  def config(env = {})
    Deploy::Config.new(env: {
      "SYRUS_APP_HOST" => "syrus.example.test",
      "SYRUS_API_TOKEN" => "secret-token",
      "SYRUS_MACOS_UPDATE_SIGNING_KEY_FILE" => key_file,
      "MACOS_WORKER_UPDATE_TIMEOUT" => "2m",
      "MACOS_WORKER_UPDATE_POLL_INTERVAL" => "10s"
    }.merge(env))
  end

  def phase(shell, env: {})
    described_class.new(config: config(env), repo: repo, shell: shell, reporter: reporter,
      waiter: Deploy::Waiter.new(clock: clock, reporter: reporter))
  end

  def shell_with_built_artifact(**options)
    DeploySpec::FakeMacShell.new(**options).tap do |shell|
      shell.build_artifact = lambda do
        release_dir = File.join(dir, "dist", "releases", "v0.0.0-deploy.#{sha}", "macos-worker")
        FileUtils.mkdir_p(release_dir)
        File.write(File.join(release_dir, "syrus-worker-macos-arm64-#{sha}.tar.gz"), "tarball")
        File.write(File.join(release_dir, "syrus-worker-macos-arm64-#{sha}.tar.gz.sig"), "c2ln\n")
      end
    end
  end

  def status(*workers)
    [ 200, JSON.generate("desired_git_sha" => sha, "workers" => workers) ]
  end

  def mac(hostname, current:, live: true, state: nil, message: nil)
    { "hostname" => hostname, "live" => live, "current" => current, "version" => current ? sha : "16254d1666",
      "updater_state" => state, "updater_message" => message }
  end

  def requests(shell)
    shell.commands.select { |mode, _| mode != :stream }.map { |_, argv| argv }
  end

  it "builds, signs, and uploads the release before any cluster changes, without exposing the token" do
    shell = shell_with_built_artifact
    shell.responses = { "" => [ 201, "{}" ] }

    phase(shell).prepare!

    build = shell.commands.first
    expect(build[1]).to eq([ "bin/release-macos-worker", "v0.0.0-deploy.#{sha}" ])
    expect(build[2]).to eq("SYRUS_MACOS_UPDATE_SIGNING_KEY_FILE" => key_file)
    upload = requests(shell).first
    expect(upload.last).to eq("https://syrus.example.test/api/v1/admin/macos_worker_releases")
    expect(upload).to include("-F", "git_sha=#{sha}", "artifact_sha256=#{Digest::SHA256.hexdigest("tarball")}")
    expect(upload.join(" ")).to include("artifact_signature=<")
    expect(shell.commands.flatten.map(&:to_s).join(" ")).not_to include("secret-token")
  end

  it "stops before any cluster changes when it cannot sign or publish the release" do
    shell = shell_with_built_artifact

    expect { phase(shell, env: { "SYRUS_MACOS_UPDATE_SIGNING_KEY_FILE" => File.join(dir, "missing.pem") }).prepare! }
      .to raise_error(Deploy::UsageError, /release signing key/)
    expect(shell.commands).to be_empty
  end

  it "activates the uploaded release after migrations and converges once every live Mac runs it" do
    shell = shell_with_built_artifact
    shell.responses = {
      "" => [ 201, "{}" ],
      "/activate" => [ 200, "{}" ],
      "/status" => [ status(mac("mac-a", current: false, state: "updating")), status(mac("mac-a", current: true)) ]
    }
    deploy = phase(shell)

    deploy.prepare!
    deploy.activate!
    deploy.await!

    paths = requests(shell).map(&:last).map { |url| url.sub(%r{\A.*/macos_worker_releases}, "") }
    expect(paths).to eq([ "", "/activate", "/status", "/status" ])
    expect(out.string).to include("1 live Mac worker(s) on #{sha}")
  end

  # The first deploy carrying this phase talks to a production Syrus that
  # predates the release endpoints.
  it "publishes after the rollout when production does not have the release endpoints yet" do
    shell = shell_with_built_artifact
    shell.responses = {
      "" => [ [ 404, "not found" ], [ 201, "{}" ] ],
      "/activate" => [ 200, "{}" ],
      "/status" => [ status(mac("mac-a", current: true)) ]
    }
    deploy = phase(shell)

    deploy.prepare!
    deploy.activate!
    deploy.await!

    paths = requests(shell).map(&:last).map { |url| url.sub(%r{\A.*/macos_worker_releases}, "") }
    expect(paths).to eq([ "", "", "/activate", "/status" ])
  end

  it "fails the deploy without rolling anything back when a Mac worker's update fails" do
    shell = shell_with_built_artifact
    shell.responses = {
      "" => [ 201, "{}" ], "/activate" => [ 200, "{}" ],
      "/status" => [ status(mac("mac-a", current: false, state: "failed", message: "bundle install failed")) ]
    }
    deploy = phase(shell)
    deploy.prepare!
    deploy.activate!

    expect { deploy.await! }.to raise_error(Deploy::Failure) { |error|
      expect(error.message).to include("update failed on mac-a", "the cluster rollout stands")
      expect(error.detail).to include("bundle install failed")
    }
  end

  it "fails the deploy when a live Mac worker has not caught up in time" do
    shell = shell_with_built_artifact
    shell.responses = {
      "" => [ 201, "{}" ], "/activate" => [ 200, "{}" ],
      "/status" => [ status(mac("mac-a", current: false, state: "updating")) ]
    }
    deploy = phase(shell)
    deploy.prepare!
    deploy.activate!

    expect { deploy.await! }.to raise_error(Deploy::Failure, /not finished after .*waiting for mac-a/)
  end

  it "does not wait on a Mac worker that is offline, and says so" do
    shell = shell_with_built_artifact
    shell.responses = {
      "" => [ 201, "{}" ], "/activate" => [ 200, "{}" ],
      "/status" => [ status(mac("mac-a", current: true), mac("mac-b", current: false, live: false)) ]
    }
    deploy = phase(shell)
    deploy.prepare!
    deploy.activate!
    deploy.await!

    expect(out.string).to include("offline, will update when back: mac-b")
  end

  it "is skipped when disabled or when the deploy does not include production" do
    [ { "SYRUS_DEPLOY_MACOS_WORKERS" => "0" } ].each do |env|
      shell = DeploySpec::FakeMacShell.new
      deploy = phase(shell, env: env)
      deploy.prepare!
      deploy.activate!
      deploy.await!
      expect(shell.commands).to be_empty
    end

    shell = DeploySpec::FakeMacShell.new
    staging_only = described_class.new(
      config: Deploy::Config.new(env: { "SYRUS_APP_HOST" => "x" }, production: false),
      repo: repo, shell: shell, reporter: reporter, waiter: Deploy::Waiter.new(clock: clock, reporter: reporter)
    )
    staging_only.prepare!
    staging_only.await!
    expect(shell.commands).to be_empty
  end
end
