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

  describe "a DaemonSet that surges and drains" do
    let(:new_image) { "ghcr.io/tkadauke/syrus-worker-dev:new" }

    # What production reported while two old compute pods drained in-flight
    # Runs: every node already had its new pod, but Kubernetes counts a node
    # as updated only once its old pod is gone.
    def daemonset
      {
        "kind" => "DaemonSet",
        "metadata" => { "name" => "syrus-worker-compute", "generation" => 7 },
        "spec" => {
          "selector" => { "matchLabels" => { "name" => "syrus-worker-compute" } },
          "updateStrategy" => { "type" => "RollingUpdate", "rollingUpdate" => { "maxSurge" => "100%", "maxUnavailable" => 0 } },
          "template" => { "spec" => { "containers" => [ { "name" => "syrus-worker", "image" => new_image } ] } }
        },
        "status" => { "observedGeneration" => 7, "desiredNumberScheduled" => 3, "currentNumberScheduled" => 3,
                      "updatedNumberScheduled" => 1, "numberAvailable" => 3 }
      }
    end

    def pod(name, node, image:, terminating: false, ready: true)
      {
        "metadata" => { "name" => name }.merge(terminating ? { "deletionTimestamp" => "2026-11-19T22:53:00Z" } : {}),
        "spec" => { "nodeName" => node, "containers" => [ { "name" => "syrus-worker", "image" => image } ] },
        "status" => { "conditions" => [ { "type" => "Ready", "status" => ready ? "True" : "False" } ] }
      }
    end

    def pods(*items) = { "items" => items }

    it "counts the rollout done once every node runs a ready new pod, however long old pods drain" do
      wait, _fake = build({
        "daemonset/syrus-worker-compute" => daemonset,
        "pods -l name=syrus-worker-compute" => pods(
          pod("new-a", "node-a", image: new_image), pod("new-b", "node-b", image: new_image), pod("new-c", "node-c", image: new_image),
          pod("old-b", "node-b", image: "old", terminating: true), pod("old-c", "node-c", image: "old", terminating: true)
        )
      })

      expect { wait.wait!("daemonset/syrus-worker-compute") }.not_to raise_error
      expect(clock.slept).to be_empty
    end

    it "keeps waiting while a node has no ready pod on the new template" do
      wait, _fake = build({
        "daemonset/syrus-worker-compute" => daemonset,
        "pods -l name=syrus-worker-compute" => [
          pods(pod("new-a", "node-a", image: new_image), pod("new-b", "node-b", image: new_image, ready: false),
            pod("old-c", "node-c", image: "old")),
          pods(pod("new-a", "node-a", image: new_image), pod("new-b", "node-b", image: new_image),
            pod("new-c", "node-c", image: new_image), pod("old-c", "node-c", image: "old", terminating: true))
        ]
      })

      wait.wait!("daemonset/syrus-worker-compute")

      expect(clock.slept).to eq([ 5 ])
    end
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
