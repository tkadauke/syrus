# frozen_string_literal: true

require_relative "deploy_helper"
require "stringio"

RSpec.describe Deploy::RolloutWait do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:reporter) { Deploy::Reporter.new(out: out, err: err) }
  let(:clock) { Deploy::Clock::Fake.new }

  def build(resources, env: {})
    fake = DeploySpec::FakeKubectl.new(namespace: "syrus-production", resources: resources)
    context = DeploySpec.context(
      kubectl: fake, config: Deploy::Config.new(env: env), clock: clock,
      reporter: reporter, label: "production"
    )
    [ described_class.new(context), fake ]
  end

  it "returns once the workload has converged" do
    wait, _fake = build({ "deployment/syrus-web" => DeploySpec.deployment("syrus-web") })

    expect { wait.wait!("deployment/syrus-web") }.not_to raise_error
    expect(clock.slept).to be_empty
  end

  it "polls until the last old pod is gone" do
    wait, _fake = build({ "deployment/syrus-web" => [
      DeploySpec.deployment("syrus-web", updated: 1, available: 1, total: 3),
      DeploySpec.deployment("syrus-web", updated: 2, available: 1, total: 3),
      DeploySpec.deployment("syrus-web")
    ] })

    wait.wait!("deployment/syrus-web")

    expect(clock.slept).to eq([ 5, 5 ])
  end

  # Kubernetes has already given up on this ReplicaSet. Sitting out our own
  # fifteen-minute timeout on top of its progress deadline only delays the
  # diagnosis, which is why this is a failure verdict and not a pending one.
  it "fails immediately once Kubernetes reports its progress deadline exceeded" do
    wait, _fake = build({ "deployment/syrus-web" => DeploySpec.deployment(
      "syrus-web", updated: 0, available: 0, conditions: [
        { "type" => "Progressing", "status" => "False", "reason" => "ProgressDeadlineExceeded",
          "message" => "ReplicaSet has timed out progressing." }
      ]
    ) })

    expect { wait.wait!("deployment/syrus-web") }
      .to raise_error(Deploy::Failure, /exceeded its progress deadline/)
    expect(clock.now).to eq(0)
  end

  it "times out with how far the rollout actually got" do
    wait, _fake = build(
      { "deployment/syrus-web" => DeploySpec.deployment("syrus-web", replicas: 3, updated: 1, available: 1, total: 3) },
      env: { "ROLLOUT_TIMEOUT" => "1m" }
    )

    expect { wait.wait!("deployment/syrus-web") }
      .to raise_error(Deploy::Failure, /1\/3 updated, 1 available/)
  end

  # Describing every pod and tailing every log is right when a deploy has
  # stopped and far too much when it is merely slow, so the full dump happens
  # once, on the failure path.
  it "gathers full diagnostics only when it gives up" do
    wait, _fake = build(
      { "deployment/syrus-web" => DeploySpec.deployment("syrus-web", updated: 0, available: 0) },
      env: { "ROLLOUT_TIMEOUT" => "10s" }
    )

    expect { wait.wait!("deployment/syrus-web") }.to raise_error(Deploy::Failure)

    expect(err.string).to include("describe pods for deployment/syrus-web")
  end

  it "says nothing beyond progress while the rollout is merely slow" do
    wait, _fake = build({ "deployment/syrus-web" => [
      DeploySpec.deployment("syrus-web", updated: 1, available: 1, total: 3),
      DeploySpec.deployment("syrus-web")
    ] })

    wait.wait!("deployment/syrus-web")

    expect(err.string).not_to include("describe pods")
  end
end
