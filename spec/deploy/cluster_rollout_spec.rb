# frozen_string_literal: true

require_relative "deploy_helper"
require "stringio"

RSpec.describe Deploy::ClusterRollout do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:reporter) { Deploy::Reporter.new(out: out, err: err) }
  let(:clock) { Deploy::Clock::Fake.new }
  let(:controls) { Deploy::ControlStack.new(reporter: reporter) }
  let(:registries) { [ "ghcr.io/tkadauke/syrus", "ghcr.io/tkadauke/syrus-worker-dev" ] }
  let(:images) { instance_double(Deploy::Images, all_registries: registries) }

  def converged(name, kind: "Deployment")
    DeploySpec.deployment(name).merge("kind" => kind)
  end

  def resources
    {
      # Rollout targets, all present and already converged so the waits return.
      "deployment/syrus-web" => converged("syrus-web").tap do |document|
        document["spec"]["template"]["spec"]["containers"] =
          [ { "name" => "syrus-web", "image" => "ghcr.io/tkadauke/syrus:old" } ]
      end,
      "deployment/syrus-worker-home" => converged("syrus-worker-home"),
      "daemonset/syrus-worker-compute" => converged("syrus-worker-compute"),
      "deployment/syrus-preview" => converged("syrus-preview"),
      # Phase-specific reads.
      "kustomization apps" => { "spec" => { "suspend" => false, "images" => [] } },
      "cronjob syrus-mysql-backup" => { "spec" => { "suspend" => false } },
      "deployment syrus-worker-home" => converged("syrus-worker-home"),
      "daemonset syrus-worker-compute" => converged("syrus-worker-compute", kind: "DaemonSet"),
      "daemonset syrus-image-prepull" => {
        "kind" => "DaemonSet", "metadata" => { "name" => "syrus-image-prepull", "generation" => 1 },
        "status" => {
          "observedGeneration" => 1, "desiredNumberScheduled" => 2,
          "updatedNumberScheduled" => 2, "numberAvailable" => 2, "currentNumberScheduled" => 2
        }
      },
      "deploy,ds,sts" => {
        "items" => [
          {
            "kind" => "Deployment", "metadata" => { "name" => "syrus-web" },
            "spec" => { "template" => { "spec" => {
              "containers" => [ { "name" => "syrus-web", "image" => "ghcr.io/tkadauke/syrus:old" } ]
            } } }
          }
        ]
      },
      /^job / => { "kind" => "Job", "status" => { "active" => 0, "conditions" => [ { "type" => "Complete", "status" => "True" } ] } },
      /^pods / => { "items" => [ { "status" => { "phase" => "Running" } } ] }
    }
  end

  # Every pod reports the revision being deployed and compiles, so the
  # verifications pass and the ordering is what is left under test.
  def exec_responses
    %w[
      deployment/syrus-web deployment/syrus-worker-home
      daemonset/syrus-worker-compute deployment/syrus-preview
    ].to_h { |target| [ "#{target} printenv GIT_SHA", { stdout: "abc1234" } ] }
  end

  def roll!
    fake = DeploySpec::FakeKubectl.new(namespace: "syrus-production", resources: resources,
      exec: exec_responses)
    context = DeploySpec.context(
      kubectl: fake, config: Deploy::Config.new(env: {}), clock: clock,
      reporter: reporter, controls: controls, label: "production"
    )
    described_class.new(context: context, images: images).roll!
    fake
  end

  # The order is the design, and each of these has been got wrong at some point.
  describe "the order of phases" do
    def positions(fake)
      actions = fake.writes.map { |write| "#{write[:namespace]} #{write[:action].join(" ")}" }
      {
        flux_suspend: actions.index { |a| a.start_with?("flux-system patch kustomization") },
        flux_pin: actions.rindex { |a| a.start_with?("flux-system patch kustomization") },
        prepull: actions.index { |a| a.include?("apply DaemonSet syrus-image-prepull") },
        migrate: actions.index { |a| a.include?("apply Job syrus-db-prepare") },
        pin: actions.index { |a| a.include?("set_image") },
        resume: actions.rindex { |a| a.start_with?("flux-system annotate kustomization") }
      }
    end

    # Pinning Flux's desired state before the live workloads is what makes
    # resuming a no-op instead of a second rollout: Flux comes back, compares,
    # and finds the pod template that just rolled out already running.
    it "pins Flux's desired images before it touches a live workload" do
      at = positions(roll!)

      expect(at[:flux_suspend]).to be < at[:pin]
      expect(at[:flux_pin]).to be < at[:resume]
    end

    # Warming nodes whose pods have already paid the pull warms nothing.
    it "warms the image before changing the live pod template" do
      at = positions(roll!)

      expect(at[:prepull]).to be < at[:pin]
    end

    # The new code must never serve traffic against a schema it has not been
    # given.
    it "applies migrations before pointing any workload at the new image" do
      at = positions(roll!)

      expect(at[:migrate]).to be < at[:pin]
    end

    it "resumes Flux last" do
      at = positions(roll!)

      expect(at[:resume]).to eq(at.values.compact.max)
    end
  end

  # Changing the image is the rollout trigger. An additional `rollout restart`
  # writes an imperative annotation, producing a ReplicaSet that differs in
  # nothing but that annotation -- and Flux strips the annotation on resume,
  # replacing every pod a second time for nothing.
  it "never issues an imperative restart" do
    fake = roll!

    expect(fake.actions.grep(/rollout/)).to be_empty
  end

  it "leaves no control outstanding after a clean rollout" do
    roll!

    expect(controls.pending).to be_empty
  end

  # Plugin and operator-owned workloads extend the watchdog budget, but a
  # workload that is both a configured rollout target and running one of our
  # images must not be counted twice -- that inflates the TTL for no reason and
  # makes the budget number meaningless as a diagnostic.
  it "counts each workload once in the flux watchdog budget" do
    fake = DeploySpec::FakeKubectl.new(namespace: "syrus-production", resources: resources,
      exec: exec_responses)
    context = DeploySpec.context(
      kubectl: fake, config: Deploy::Config.new(env: {}), clock: clock,
      reporter: reporter, controls: controls, label: "production"
    )
    described_class.new(context: context, images: images).roll!

    watchdog = fake.writes.find { |write| write[:manifest]&.dig("metadata", "name")&.start_with?("syrus-flux-resume") }
    # Four configured targets are present, and the only discovered workload is
    # one of them, so the budget is for four -- not five.
    expected = Deploy::Config.new(env: {}).flux_suspend_budget_seconds(4)
    expect(watchdog.dig(:manifest, "spec", "activeDeadlineSeconds")).to eq(expected + 120)
  end

  it "reports the cluster as rolled once everything is verified" do
    roll!

    expect(out.string).to include("production rolled to abc1234")
  end

  # A workload that is simply not installed here -- the preview service on a
  # cluster that does not run previews -- is skipped with a note. None of them
  # existing is a different matter: it means this is not a Syrus namespace, and
  # proceeding would suspend Flux and migrate a database for nothing.
  it "skips a rollout target this namespace does not run" do
    fake = DeploySpec::FakeKubectl.new(
      namespace: "syrus-production",
      resources: resources.except("deployment/syrus-preview"),
      exec: exec_responses
    )
    context = DeploySpec.context(
      kubectl: fake, config: Deploy::Config.new(env: {}), clock: clock,
      reporter: reporter, controls: controls, label: "production"
    )

    described_class.new(context: context, images: images).roll!

    expect(out.string).to include("deployment/syrus-preview not found in syrus-production — skipping")
  end

  it "refuses a namespace that runs none of the rollout targets" do
    fake = DeploySpec::FakeKubectl.new(namespace: "elsewhere", resources: {})
    context = DeploySpec.context(
      kubectl: fake, config: Deploy::Config.new(env: {}), clock: clock,
      reporter: reporter, controls: controls, label: "production"
    )

    expect { described_class.new(context: context, images: images).roll! }
      .to raise_error(Deploy::Failure, /no rollout targets found in elsewhere/)
  end
end
