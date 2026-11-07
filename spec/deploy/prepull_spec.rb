# frozen_string_literal: true

require_relative "deploy_helper"
require "stringio"

RSpec.describe Deploy::Prepull do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:reporter) { Deploy::Reporter.new(out: out, err: err) }
  let(:controls) { Deploy::ControlStack.new(reporter: reporter) }
  let(:clock) { Deploy::Clock::Fake.new }

  let(:affinity) do
    {
      "nodeAffinity" => {
        "requiredDuringSchedulingIgnoredDuringExecution" => {
          "nodeSelectorTerms" => [
            { "matchExpressions" => [ { "key" => "node-role.kubernetes.io/master", "operator" => "DoesNotExist" } ] }
          ]
        }
      }
    }
  end

  def compute_daemonset(spec = {})
    {
      "kind" => "DaemonSet", "metadata" => { "name" => "syrus-worker-compute" },
      "spec" => { "template" => { "spec" => spec } }
    }
  end

  def prepull_status(desired: 6, updated: 6, available: 6, current: 6)
    {
      "kind" => "DaemonSet", "metadata" => { "name" => "syrus-image-prepull", "generation" => 1 },
      "status" => {
        "observedGeneration" => 1, "desiredNumberScheduled" => desired,
        "updatedNumberScheduled" => updated, "numberAvailable" => available,
        "currentNumberScheduled" => current
      }
    }
  end

  def build(resources, env: {})
    fake = DeploySpec::FakeKubectl.new(namespace: "syrus-production", resources: resources)
    context = DeploySpec.context(
      kubectl: fake, config: Deploy::Config.new(env: env), clock: clock,
      reporter: reporter, controls: controls, label: "production"
    )
    [ described_class.new(context), fake ]
  end

  it "skips when pre-pull is turned off" do
    prepull, fake = build({}, env: { "PREPULL" => "0" })

    prepull.warm!

    expect(fake.writes).to be_empty
    expect(out.string).to include("skipping image pre-pull (PREPULL=0)")
  end

  it "skips a namespace with no compute DaemonSet" do
    prepull, fake = build({})

    prepull.warm!

    expect(fake.writes).to be_empty
    expect(out.string).to include("no compute DaemonSet")
  end

  # Environments genuinely differ in which nodes carry the worker role: one
  # cluster keeps an anti-control-plane nodeAffinity, another lets its
  # control-plane nodes run workers too. Hardcoding either rule warms the wrong
  # nodes in the other environment -- and warming a node that will never run
  # the workload is worse than wasteful when that node has a small disk and
  # this image is multi-gigabyte.
  it "copies placement, tolerations and pull secrets from the live compute DaemonSet" do
    prepull, fake = build({
      "daemonset syrus-worker-compute" => compute_daemonset(
        "affinity" => affinity,
        "tolerations" => [ { "key" => "dedicated", "operator" => "Exists" } ],
        "imagePullSecrets" => [ { "name" => "ghcr" } ]
      ),
      "daemonset syrus-image-prepull" => prepull_status
    })

    prepull.warm!

    pod_spec = fake.writes.first[:manifest].dig("spec", "template", "spec")
    expect(pod_spec["affinity"]).to eq(affinity)
    expect(pod_spec["tolerations"]).to eq([ { "key" => "dedicated", "operator" => "Exists" } ])
    expect(pod_spec["imagePullSecrets"]).to eq([ { "name" => "ghcr" } ])
    expect(pod_spec.dig("containers", 0, "image")).to eq("ghcr.io/tkadauke/syrus-worker-dev:abc1234")
  end

  # The bash implementation interpolated a variable nothing ever assigned.
  # Under `set -u` the heredoc aborted, the apply never ran, and every deploy
  # silently skipped the pre-pull -- leaving each node to pull a
  # multi-gigabyte image cold during its own rollout. A hash with a missing key
  # raises where it is built, by name; absent placement just has no placement.
  it "builds a valid manifest from a DaemonSet that specifies no placement at all" do
    prepull, fake = build({
      "daemonset syrus-worker-compute" => compute_daemonset,
      "daemonset syrus-image-prepull" => prepull_status
    })

    prepull.warm!

    pod_spec = fake.writes.first[:manifest].dig("spec", "template", "spec")
    expect(pod_spec["affinity"]).to eq({})
    expect(pod_spec["tolerations"]).to eq([])
    expect(pod_spec["imagePullSecrets"]).to eq([])
  end

  it "tears the DaemonSet down once every node is warm" do
    prepull, fake = build({
      "daemonset syrus-worker-compute" => compute_daemonset,
      "daemonset syrus-image-prepull" => prepull_status
    })

    prepull.warm!

    expect(fake.actions.last).to eq("delete daemonset syrus-image-prepull")
    expect(controls).to be_empty
    expect(out.string).to include("image warm on every compute node")
  end

  # The rollout pulls the image itself, exactly as it did before this phase
  # existed, so a timeout here costs the time it was meant to save and nothing
  # else. Failing the deploy over it would be strictly worse than not having
  # the optimisation.
  it "is not a deploy failure when nodes do not finish warming in time" do
    prepull, fake = build(
      {
        "daemonset syrus-worker-compute" => compute_daemonset,
        "daemonset syrus-image-prepull" => prepull_status(updated: 2, available: 2)
      },
      env: { "PREPULL_TIMEOUT" => "1m" }
    )

    expect { prepull.warm! }.not_to raise_error
    expect(err.string).to include("continuing; the rollout will pull")
    expect(fake.actions.last).to eq("delete daemonset syrus-image-prepull")
  end
end
