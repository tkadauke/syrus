# frozen_string_literal: true

require_relative "deploy_helper"
require "stringio"

RSpec.describe Deploy::Verifications do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:reporter) { Deploy::Reporter.new(out: out, err: err) }
  let(:clock) { Deploy::Clock::Fake.new }
  let(:targets) { [ "deployment/syrus-web", "deployment/syrus-worker-home" ] }

  def build(exec:, resources: nil, dry_run: false)
    resources ||= {
      "deployment/syrus-web" => DeploySpec.deployment("syrus-web"),
      "deployment/syrus-worker-home" => DeploySpec.deployment("syrus-worker-home"),
      "daemonset/syrus-worker-compute" => DeploySpec.deployment("syrus-worker-compute")
    }
    fake = DeploySpec::FakeKubectl.new(namespace: "syrus-production", resources: resources, exec: exec)
    context = DeploySpec.context(
      kubectl: fake, clock: clock, reporter: reporter, dry_run: dry_run, label: "production"
    )
    [ described_class.new(context), fake ]
  end

  describe "the revision check" do
    # A converged rollout is not the same claim as "the pods run this code". An
    # imperative restart annotation can be stripped by Flux's next apply,
    # leaving the controller with no progress to report and nothing replaced;
    # and a workload on an untagged image can bring up new pods before kubelet
    # notices that :latest moved. Both end with a happy controller and stale
    # code, so the pods themselves are the only witness that counts.
    it "passes when every pod reports the revision being deployed" do
      verifications, _fake = build(exec: {
        "deployment/syrus-web printenv GIT_SHA" => { stdout: "abc1234\n" },
        "deployment/syrus-worker-home printenv GIT_SHA" => { stdout: "abc1234\n" }
      })

      expect { verifications.verify_revision!(targets) }.not_to raise_error
    end

    it "fails and names every workload still serving an older image" do
      verifications, _fake = build(exec: {
        "deployment/syrus-web printenv GIT_SHA" => { stdout: "abc1234\n" },
        "deployment/syrus-worker-home printenv GIT_SHA" => { stdout: "old9999\n" }
      })

      expect { verifications.verify_revision!(targets) }
        .to raise_error(Deploy::Failure, /deployment\/syrus-worker-home still serve an older image/)
      expect(err.string).to include("pods running 'old9999' but expected abc1234")
    end

    it "says <empty> rather than nothing when a pod reports no revision at all" do
      verifications, _fake = build(exec: {
        "deployment/syrus-web printenv GIT_SHA" => { stdout: "" },
        "deployment/syrus-worker-home printenv GIT_SHA" => { stdout: "abc1234" }
      })

      expect { verifications.verify_revision!(targets) }.to raise_error(Deploy::Failure)
      expect(err.string).to include("pods running '<empty>'")
    end

    it "skips a rollout target this namespace does not run" do
      verifications, _fake = build(
        exec: { "deployment/syrus-web printenv GIT_SHA" => { stdout: "abc1234" } },
        resources: { "deployment/syrus-web" => DeploySpec.deployment("syrus-web") }
      )

      expect { verifications.verify_revision!(targets) }.not_to raise_error
    end
  end

  # kubectl exec races a rollout: the pod it resolved a moment ago can be
  # replaced between resolution and attach.
  describe "racing the rollout" do
    it "retries an exec whose target disappeared" do
      verifications, _fake = build(exec: {
        "deployment/syrus-web printenv GIT_SHA" => [
          { stderr: "error: unable to upgrade connection: pod does not exist", status: 1 },
          { stdout: "abc1234", status: 0 }
        ],
        "deployment/syrus-worker-home printenv GIT_SHA" => { stdout: "abc1234" }
      })

      expect { verifications.verify_revision!([ "deployment/syrus-web", "deployment/syrus-worker-home" ]) }
        .not_to raise_error
      expect(clock.slept).to eq([ 5 ])
    end

    # A genuine failure of the command is not a race, and retrying it five
    # times just makes the operator wait longer for the same answer.
    it "does not retry a command that simply failed" do
      verifications, fake = build(exec: {
        "deployment/syrus-worker-home bash" => { stderr: "gcc: not found", status: 1 }
      })

      expect { verifications.verify_native_toolchain! }.to raise_error(Deploy::Failure)
      expect(fake.actions.count { |action| action.start_with?("exec deployment/syrus-worker-home") }).to eq(1)
    end
  end

  describe "the native toolchain check" do
    # The worker image exists so an agent inside a pod can build and test what
    # it writes. A missing toolchain layer breaks every native gem install in
    # every workflow; one compile here is cheaper than finding out that way.
    it "fails with what to look at when a worker cannot compile" do
      verifications, _fake = build(exec: {
        "deployment/syrus-worker-home bash" => { stdout: "cannot find -lruby", status: 1 }
      })

      expect { verifications.verify_native_toolchain! }
        .to raise_error(Deploy::Failure, /cannot compile a native extension as uid 1000/) { |error|
          expect(error.detail).to include("not running the worker-dev image")
        }
    end

    it "runs against every worker workload" do
      verifications, fake = build(exec: {})

      verifications.verify_native_toolchain!

      expect(fake.actions.grep(/\Aexec/).length).to eq(2)
    end
  end

  describe "the coworker confinement check" do
    # Opt-in: a cluster that does not run confined coworkers must not be failed
    # for not running them.
    it "is skipped unless the worker asks for it" do
      verifications, fake = build(exec: {
        "deployment/syrus-worker-home printenv SYRUS_VERIFY_COWORKER_CONFINEMENT" => { stdout: "" },
        "daemonset/syrus-worker-compute printenv SYRUS_VERIFY_COWORKER_CONFINEMENT" => { stdout: "" }
      })

      verifications.verify_coworker_confinement!

      expect(fake.actions.grep(/bin\/rails/)).to be_empty
    end

    it "fails when a worker that requires confinement cannot prove it" do
      verifications, _fake = build(exec: {
        "deployment/syrus-worker-home printenv SYRUS_VERIFY_COWORKER_CONFINEMENT" => { stdout: "true" },
        "deployment/syrus-worker-home bin/rails" => { stderr: '{"runtime_verified":false}', status: 1 }
      })

      expect { verifications.verify_coworker_confinement! }
        .to raise_error(Deploy::Failure, /confined coworker rollout verification failed/)
    end
  end

  # There are no new pods to interrogate, so every check would compare against
  # the previous revision and fail a dry run that did exactly what it was asked
  # to. The bash implementation got this half-right by accident: it classified
  # `exec` as a mutation, so its dry run printed the verifications and never
  # ran them.
  it "is skipped entirely in a dry run" do
    verifications, fake = build(exec: {}, dry_run: true)

    verifications.verify_all!(targets)

    expect(fake.writes).to be_empty
  end
end
