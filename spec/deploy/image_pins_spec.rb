# frozen_string_literal: true

require_relative "deploy_helper"
require "stringio"

RSpec.describe Deploy::ImagePins do
  let(:registries) do
    [
      "ghcr.io/tkadauke/syrus",
      "ghcr.io/tkadauke/syrus-worker-dev",
      "ghcr.io/tkadauke/syrus-plugin-git-mirror"
    ]
  end

  def workload(kind, name, containers: [], init: [])
    {
      "kind" => kind,
      "metadata" => { "name" => name },
      "spec" => { "template" => { "spec" => { "containers" => containers, "initContainers" => init } } }
    }
  end

  def container(name, image)
    { "name" => name, "image" => image }
  end

  def pins(items)
    fake = DeploySpec::FakeKubectl.new(resources: { "deploy,ds,sts" => { "items" => items } })
    context = DeploySpec.context(kubectl: fake, reporter: DeploySpec.reporter)
    [ described_class.new(context, registries: registries), fake ]
  end

  it "pins every container of every workload running one of our images" do
    subject, fake = pins([
      workload("Deployment", "syrus-web",
        containers: [ container("syrus-web", "ghcr.io/tkadauke/syrus:old") ],
        init: [ container("db-prepare", "ghcr.io/tkadauke/syrus:old") ]),
      workload("DaemonSet", "syrus-worker-compute",
        containers: [ container("syrus-worker", "ghcr.io/tkadauke/syrus-worker-dev:old") ],
        init: [ container("seed-mise", "ghcr.io/tkadauke/syrus-worker-dev:old") ])
    ])

    subject.pin!

    expect(fake.actions).to eq([
      "set_image deployment/syrus-web syrus-web=ghcr.io/tkadauke/syrus:abc1234 db-prepare=ghcr.io/tkadauke/syrus:abc1234",
      "set_image daemonset/syrus-worker-compute syrus-worker=ghcr.io/tkadauke/syrus-worker-dev:abc1234 seed-mise=ghcr.io/tkadauke/syrus-worker-dev:abc1234"
    ])
  end

  # The previous implementation named four workloads and eight container names
  # in the script, and the failure that produced -- "a workload was added
  # without a matching entry" -- was written into its own error message.
  # Discovery is what makes that failure unreachable.
  it "finds a workload nothing in this script has ever heard of" do
    subject, fake = pins([
      workload("StatefulSet", "some-operators-own-thing",
        containers: [ container("app", "ghcr.io/tkadauke/syrus-plugin-git-mirror:whatever") ])
    ])

    subject.pin!

    expect(fake.actions).to eq([
      "set_image statefulset/some-operators-own-thing app=ghcr.io/tkadauke/syrus-plugin-git-mirror:abc1234"
    ])
  end

  it "leaves containers running somebody else's images alone" do
    subject, fake = pins([
      workload("Deployment", "syrus-web", containers: [
        container("syrus-web", "ghcr.io/tkadauke/syrus:old"),
        container("sidecar", "docker.io/library/redis:7")
      ])
    ])

    subject.pin!

    expect(fake.actions.first).not_to include("sidecar")
  end

  describe "matching the repository rather than the tag" do
    # Matching on the repository is what lets this find a workload that is
    # already on the right revision, or on a digest, or on `:latest`.
    it "recognises a digest reference" do
      subject, fake = pins([
        workload("Deployment", "syrus-web",
          containers: [ container("syrus-web", "ghcr.io/tkadauke/syrus@sha256:#{"a" * 64}") ])
      ])

      subject.pin!

      expect(fake.actions.first).to include("syrus-web=ghcr.io/tkadauke/syrus:abc1234")
    end

    # Only a trailing `:tag` with no `/` after it is a tag -- a registry host
    # with a port must not lose its port.
    it "does not mistake a registry port for a tag" do
      subject, _fake = pins([
        workload("Deployment", "x", containers: [ container("c", "registry.local:5000/tkadauke/syrus:old") ])
      ])

      expect(subject.our_containers).to be_empty
    end
  end

  # Pinning is what triggers each rollout and nothing waits between pins, so
  # the order does not change the outcome -- but a deploy whose first visible
  # move is always the web deployment is easier to read than one that follows
  # whatever order kubectl listed resources in.
  it "pins the configured rollout targets first, in the operator's order" do
    subject, fake = pins([
      workload("Deployment", "syrus-git-mirror",
        containers: [ container("git-mirror", "ghcr.io/tkadauke/syrus-plugin-git-mirror:old") ]),
      workload("DaemonSet", "syrus-worker-compute",
        containers: [ container("syrus-worker", "ghcr.io/tkadauke/syrus-worker-dev:old") ]),
      workload("Deployment", "syrus-web",
        containers: [ container("syrus-web", "ghcr.io/tkadauke/syrus:old") ])
    ])

    subject.pin!

    expect(fake.actions.map { |action| action.split[1] })
      .to eq(%w[deployment/syrus-web daemonset/syrus-worker-compute deployment/syrus-git-mirror])
  end

  # A namespace where nothing runs a Syrus image is not a Syrus namespace, and
  # pinning nothing then waiting for nothing would report a successful deploy.
  it "refuses to report success when there is nothing of ours to pin" do
    subject, _fake = pins([
      workload("Deployment", "unrelated", containers: [ container("c", "docker.io/library/nginx:1") ])
    ])

    expect { subject.pin! }.to raise_error(Deploy::Failure, /nothing to pin/)
  end

  it "records what it pinned so the rollout knows what to wait for" do
    subject, _fake = pins([
      workload("Deployment", "syrus-web", containers: [ container("syrus-web", "ghcr.io/tkadauke/syrus:old") ])
    ])

    subject.pin!

    expect(subject.pinned_targets).to eq([ "deployment/syrus-web" ])
  end
end
