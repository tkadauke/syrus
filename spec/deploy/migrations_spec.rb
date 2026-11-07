# frozen_string_literal: true

require_relative "deploy_helper"
require "stringio"

RSpec.describe Deploy::Migrations do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:reporter) { Deploy::Reporter.new(out: out, err: err) }
  let(:clock) { Deploy::Clock::Fake.new }
  let(:controls) { Deploy::ControlStack.new(reporter: reporter) }

  def web_deployment
    {
      "kind" => "Deployment",
      "metadata" => { "name" => "syrus-web" },
      "spec" => {
        "template" => {
          "spec" => {
            "serviceAccountName" => "syrus",
            "imagePullSecrets" => [ { "name" => "ghcr" } ],
            "volumes" => [ { "name" => "data", "emptyDir" => {} } ],
            "nodeSelector" => { "role" => "web" },
            "tolerations" => [],
            "initContainers" => [
              {
                "name" => "db-prepare",
                "image" => "ghcr.io/tkadauke/syrus:old",
                "command" => [ "./bin/rails" ],
                "args" => [ "db:prepare" ],
                "env" => [ { "name" => "RAILS_ENV", "value" => "production" } ],
                "envFrom" => [ { "secretRef" => { "name" => "syrus-secrets" } } ],
                "volumeMounts" => [ { "name" => "data", "mountPath" => "/data" } ]
              }
            ],
            "containers" => [
              {
                "name" => "syrus-web",
                "image" => "ghcr.io/tkadauke/syrus:old",
                "ports" => [ { "containerPort" => 3000 } ],
                "readinessProbe" => { "httpGet" => { "path" => "/up" } },
                "livenessProbe" => { "httpGet" => { "path" => "/up" } },
                "startupProbe" => { "httpGet" => { "path" => "/up" } },
                "lifecycle" => { "preStop" => {} }
              }
            ]
          }
        }
      }
    }
  end

  def job(complete: false, failed: false, active: 1)
    conditions = []
    conditions << { "type" => "Complete", "status" => "True" } if complete
    conditions << { "type" => "Failed", "status" => "True" } if failed
    { "kind" => "Job", "status" => { "active" => active, "conditions" => conditions } }
  end

  def pods(phase: "Running", waiting: nil, unschedulable: false)
    status = { "status" => { "phase" => phase } }
    if waiting
      status["status"]["containerStatuses"] = [ { "state" => { "waiting" => { "reason" => waiting } } } ]
    end
    if unschedulable
      status["status"]["conditions"] = [
        { "type" => "PodScheduled", "status" => "False", "reason" => "Unschedulable" }
      ]
    end
    { "items" => [ status ] }
  end

  def kubectl(resources)
    DeploySpec::FakeKubectl.new(
      namespace: "syrus-production",
      resources: { "deployment/syrus-web" => web_deployment }.merge(resources),
      logs: logs
    )
  end

  let(:logs) { "" }

  def run!(resources, env: {}, dry_run: false)
    fake = kubectl(resources)
    context = DeploySpec.context(
      kubectl: fake, config: Deploy::Config.new(env: env), clock: clock,
      reporter: reporter, controls: controls, dry_run: dry_run, label: "production"
    )
    [ described_class.new(context).tap(&:run!), fake ]
  rescue Deploy::Failure => e
    @failure = e
    [ nil, fake ]
  end

  describe "the happy path" do
    it "applies the Job, waits for it, and cleans it up" do
      _, fake = run!({ /^job / => job(complete: true), /^pods / => pods })

      expect(@failure).to be_nil
      expect(fake.actions).to include("apply Job #{fake.writes.first[:manifest].dig("metadata", "name")}")
      expect(fake.actions.last).to start_with("delete job syrus-db-prepare-")
      expect(out.string).to include("database migrations complete")
    end
  end

  describe "the Job manifest" do
    subject(:manifest) do
      _, fake = run!({ /^job / => job(complete: true), /^pods / => pods })
      fake.writes.first[:manifest]
    end

    # Running them from the new image is the whole point: a running web pod
    # would answer out of the old image's db/migrate directory and report
    # nothing pending no matter what the database looks like.
    it "runs db:prepare from the image being deployed" do
      container = manifest.dig("spec", "template", "spec", "containers", 0)

      expect(container["image"]).to eq("ghcr.io/tkadauke/syrus:abc1234")
      expect(container["command"]).to eq([ "./bin/rails" ])
      expect(container["args"]).to eq([ "db:prepare" ])
    end

    # Derived from the live web deployment rather than written out in the
    # script, so it inherits whatever that deployment actually needs to reach
    # the database. A hand-maintained copy drifts, and the way it drifts is
    # that migrations start failing on a cluster whose web pods are fine.
    it "inherits the web deployment's credentials, volumes and placement" do
      pod_spec = manifest.dig("spec", "template", "spec")
      container = pod_spec.dig("containers", 0)

      expect(pod_spec["serviceAccountName"]).to eq("syrus")
      expect(pod_spec["imagePullSecrets"]).to eq([ { "name" => "ghcr" } ])
      expect(pod_spec["volumes"]).to eq([ { "name" => "data", "emptyDir" => {} } ])
      expect(pod_spec["nodeSelector"]).to eq({ "role" => "web" })
      expect(container["envFrom"]).to eq([ { "secretRef" => { "name" => "syrus-secrets" } } ])
      expect(container["volumeMounts"]).to eq([ { "name" => "data", "mountPath" => "/data" } ])
    end

    it "drops the things a one-shot Job must not inherit" do
      container = manifest.dig("spec", "template", "spec", "containers", 0)

      expect(container.keys).not_to include("ports", "readinessProbe", "livenessProbe",
        "startupProbe", "lifecycle")
      expect(manifest.dig("spec", "template", "spec", "restartPolicy")).to eq("Never")
    end

    # A migration that failed needs an operator, not another pod racing the
    # advisory lock.
    it "never retries itself" do
      expect(manifest.dig("spec", "backoffLimit")).to eq(0)
    end

    # Kubernetes must not kill the Job before this phase decides to, or the
    # deadline it enforces becomes the real migration timeout.
    it "gives Kubernetes a deadline past this phase's own budget" do
      config = Deploy::Config.new(env: {})

      expect(manifest.dig("spec", "activeDeadlineSeconds"))
        .to be > config.migration_start_timeout + config.migration_run_timeout
    end
  end

  describe "the two budgets" do
    # The correction this rewrite exists for. A pod that cannot start is broken
    # now; applying migrations is legitimately slow. One shared clock failed a
    # deploy -- and rolled production back -- over a data migration that was
    # running correctly and would have finished.
    it "lets a migration run far longer than the startup budget allows" do
      pending_reads = Array.new(100) { job(complete: false) }
      pending_reads << job(complete: true)

      run!(
        { /^job / => pending_reads, /^pods / => pods },
        env: { "MIGRATION_START_TIMEOUT" => "1m", "MIGRATION_RUN_TIMEOUT" => "30m" }
      )

      expect(@failure).to be_nil
      # Well past the one-minute startup budget.
      expect(clock.now).to be > 60
    end

    it "fails on the startup budget while the pod has not started" do
      run!(
        { /^job / => job(complete: false, active: 0), /^pods / => pods(phase: "Pending") },
        env: { "MIGRATION_START_TIMEOUT" => "1m" }
      )

      expect(@failure.message).to include("migration pod startup")
      expect(clock.now).to be_within(5).of(60)
    end

    it "fails on the run budget once the pod is running" do
      run!(
        { /^job / => job(complete: false), /^pods / => pods },
        env: { "MIGRATION_START_TIMEOUT" => "1m", "MIGRATION_RUN_TIMEOUT" => "5m" }
      )

      expect(@failure.message).to include("database migrations")
      expect(@failure.message).not_to include("startup")
      # The startup budget was not spent: the pod was already running.
      expect(clock.now).to be_within(10).of(300)
    end

    # Waiting out a half-hour budget on a state that will never resolve only
    # delays the diagnosis.
    it "fails immediately on a state that will never resolve" do
      run!(
        { /^job / => job(complete: false, active: 0), /^pods / => pods(phase: "Pending", waiting: "ImagePullBackOff") },
        env: { "MIGRATION_START_TIMEOUT" => "10m" }
      )

      expect(@failure.message).to include("ImagePullBackOff")
      expect(clock.now).to eq(0)
    end

    it "names an unschedulable pod rather than timing out silently" do
      run!(
        { /^job / => job(complete: false, active: 0), /^pods / => pods(phase: "Pending", unschedulable: true) },
        env: { "MIGRATION_START_TIMEOUT" => "10m" }
      )

      expect(@failure.message).to include("Unschedulable")
    end
  end

  describe "an interrupted deploy" do
    # The single most destructive thing the previous implementation did.
    # Deleting a Job propagates to its pod, SIGTERMing Rails mid-ALTER, and it
    # did that from its exit handler on every failure path -- so interrupting a
    # slow deploy was the worst available action while feeling like the careful
    # one.
    it "leaves a migration that is still running alone, and says how to watch it" do
      _, fake = run!(
        { /^job / => job(complete: false), /^pods / => pods },
        env: { "MIGRATION_RUN_TIMEOUT" => "1m" }
      )

      controls.unwind(interrupted: true)

      expect(err.string).to include("still applying migrations")
      expect(err.string).to include("kubectl logs -f -n syrus-production job/syrus-db-prepare-")
      expect(fake.actions.grep(/\Adelete job/)).to be_empty
    end

    it "does clean up a Job that has finished" do
      fake = kubectl(/^job / => job(complete: true, active: 0), /^pods / => pods)
      context = DeploySpec.context(
        kubectl: fake, config: Deploy::Config.new(env: {}), clock: clock,
        reporter: reporter, controls: controls, label: "production"
      )
      described_class.new(context).run!

      # The happy path already deleted it and discharged the entry, so there is
      # nothing dangerous left on the stack.
      expect(controls).to be_empty
    end
  end

  describe "losing the migration advisory lock" do
    let(:logs) { "ActiveRecord::ConcurrentMigrationError: Another migration is currently running" }

    # Rails takes a MySQL advisory lock around migrations, and the web pod's
    # own db-prepare initContainer runs on every replica at every boot. Losing
    # that race means "someone else is doing exactly this work", which is
    # transient by construction.
    it "retries after a backoff" do
      run!(
        {
          # Attempt one loses the lock; attempt two gets it and completes.
          /^job syrus-db-prepare/ => [
            job(complete: false), job(failed: true),
            job(complete: false), job(complete: true)
          ],
          # The probe reports migrations still pending, so the retry is needed.
          /^job syrus-db-check/ => [ job(complete: false), job(failed: true) ],
          /^pods / => pods
        },
        env: { "DB_PREPARE_ATTEMPTS" => "4", "DB_PREPARE_RETRY_DELAY" => "20s" }
      )

      expect(out.string).to include("holds the migration lock; retrying in 20s")
      expect(clock.slept).to include(20)
    end

    # The process that won the lock runs the same migrations from the same
    # image, so by the time we are told "someone else is migrating" the schema
    # may already be exactly where this deploy wants it. A deploy that aborts
    # over migrations another process already applied is a false negative --
    # and that false negative has rolled production back.
    it "succeeds without retrying when the schema is already where it needs to be" do
      run!(
        {
          /^job syrus-db-prepare/ => [ job(complete: false), job(failed: true) ],
          /^job syrus-db-check/ => [ job(complete: false), job(complete: true) ],
          /^pods / => pods
        },
        env: { "DB_PREPARE_ATTEMPTS" => "4" }
      )

      expect(@failure).to be_nil
      expect(out.string).to include("already applied by the process holding the lock")
      expect(clock.slept).to be_empty
    end

    it "gives up after the configured number of attempts" do
      run!(
        {
          /^job syrus-db-prepare/ => Array.new(20) { |i| i.even? ? job(complete: false) : job(failed: true) },
          /^job syrus-db-check/ => Array.new(20) { job(failed: true) },
          /^pods / => pods
        },
        env: { "DB_PREPARE_ATTEMPTS" => "2" }
      )

      expect(@failure.message).to include("still pending after 2 attempts")
    end
  end

  describe "a migration that genuinely failed" do
    let(:logs) { "PG::UndefinedColumn: ERROR: column \"nope\" does not exist" }

    # Not the lock race. One attempt, then stop, with everything an operator
    # needs to see.
    it "fails on the first attempt and reports the Job and its logs" do
      run!({ /^job / => [ job(complete: false), job(failed: true) ], /^pods / => pods },
        env: { "DB_PREPARE_ATTEMPTS" => "4" })

      expect(@failure.message).to include("database migration job failed")
      expect(@failure.detail).to include("describe output")
      expect(@failure.detail).to include("PG::UndefinedColumn")
    end
  end

  it "refuses to migrate a namespace with no web deployment" do
    fake = DeploySpec::FakeKubectl.new(namespace: "syrus-production", resources: {})
    context = DeploySpec.context(kubectl: fake, reporter: reporter, controls: controls, label: "production")

    expect { described_class.new(context).run! }
      .to raise_error(Deploy::Failure, /deployment\/syrus-web not found/)
  end
end
