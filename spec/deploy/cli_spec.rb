# frozen_string_literal: true

require_relative "deploy_helper"
require "open3"

RSpec.describe Deploy::CLI do
  def parse(*argv, env: {})
    described_class.parse(argv, env: env)
  end

  it "deploys both clusters by default" do
    config = parse
    expect([ config.staging, config.production ]).to eq([ true, true ])
  end

  it "narrows to one cluster" do
    expect(parse("--staging").production).to be(false)
    expect(parse("--production").staging).to be(false)
  end

  it "takes --build-only and --skip-build" do
    expect(parse("--build-only").build_only).to be(true)
    expect(parse("--skip-build").skip_build).to be(true)
  end

  it "implies --skip-build for --dry-run" do
    config = parse("--dry-run")
    expect(config.dry_run).to be(true)
    expect(config.skip_build).to be(true)
  end

  it "rejects an unknown argument rather than ignoring it" do
    expect { parse("--prod") }.to raise_error(Deploy::UsageError, /unknown argument: --prod/)
  end

  # Exit 2 for "you asked wrong" so a wrapper can tell it from a failed deploy.
  it "exits 2 on a usage error" do
    expect { parse("--prod") }.to raise_error(Deploy::UsageError) { |error|
      expect(error.exit_status).to eq(2)
    }
  end

  it "answers --help without building a config" do
    expect(parse("--help")).to eq(:help)
    expect(parse("-h")).to eq(:help)
  end

  describe "the usage text" do
    it "documents every flag the parser accepts" do
      %w[--staging --production --build-only --skip-build --dry-run].each do |flag|
        expect(described_class::USAGE).to include(flag)
      end
    end

    # The two timeouts an operator actually reaches for when a deploy stalls.
    it "names the migration budgets and their defaults" do
      expect(described_class::USAGE).to include("MIGRATION_START_TIMEOUT", "MIGRATION_RUN_TIMEOUT")
    end

    it "points at the fallback" do
      expect(described_class::USAGE).to include("bin/deploy-legacy")
    end
  end
end

RSpec.describe "bin/deploy" do
  let(:root) { DeploySpec::ROOT }

  it "runs and prints its usage" do
    stdout, stderr, status = Open3.capture3(File.join(root, "bin/deploy"), "--help", chdir: root)

    expect(status).to be_success, stderr
    expect(stdout).to include("build this revision and roll it out")
  end

  it "refuses an unknown flag with exit 2" do
    _stdout, stderr, status = Open3.capture3(File.join(root, "bin/deploy"), "--nope", chdir: root)

    expect(status.exitstatus).to eq(2)
    expect(stderr).to include("unknown argument: --nope")
  end

  # The fallback the rewrite is allowed to exist because of. It has to stay
  # runnable, and it has to keep taking the same flags, or "use the old one"
  # is not an option an operator can actually take at the moment they need it.
  describe "the bash fallback" do
    it "is still present and executable" do
      expect(File.executable?(File.join(root, "bin/deploy-legacy"))).to be(true)
    end

    it "still answers the same flags" do
      stdout, stderr, status = Open3.capture3("bash", File.join(root, "bin/deploy-legacy"), "--help", chdir: root)

      expect(status).to be_success, stderr
      %w[--staging --production --build-only --skip-build --dry-run].each do |flag|
        expect(stdout).to include(flag)
      end
    end
  end

  # lib/deploy is bin/deploy's implementation, not application code: it runs on
  # an operator's machine, loads no Rails, and a web pod has no business
  # holding the code that replaces it.
  it "is excluded from the application's autoload paths" do
    application = File.read(File.join(root, "config/application.rb"))

    expect(application).to match(/autoload_lib\(ignore: %w\[[^\]]*\bdeploy\b/)
  end

  # Nothing under lib/deploy may reach for Rails, or bin/deploy stops working
  # on a machine that cannot boot the app -- which is most of the machines it
  # has to work on.
  it "loads nothing from Rails" do
    offenders = Dir[File.join(root, "lib/deploy/*.rb")].select do |path|
      code = File.readlines(path).grep_v(/\A\s*#/).join
      code.match?(/\bRails\.|ActiveSupport|require ["']rails/)
    end

    expect(offenders).to be_empty
  end
end
