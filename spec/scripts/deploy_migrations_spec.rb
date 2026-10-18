require "spec_helper"
require "json"
require "open3"
require "shellwords"
require "tmpdir"

RSpec.describe "bin/deploy database migrations" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:deploy) { File.read(File.join(root, "bin/deploy")) }

  def bash(script, env = {})
    Open3.capture3(env, "bash", "-c", script, chdir: root)
  end

  # Every function the migration path needs, lifted out of bin/deploy so the
  # examples can drive it against a fake kubectl on PATH.
  def migration_functions
    %w[
      run_database_migrations apply_and_wait_db_prepare_job
      wait_for_db_prepare_job duration_to_seconds delete_db_prepare_job
    ].map { |name| deploy[/^#{name}\(\) \{.*?\n\}/m] or raise "#{name} not found in bin/deploy" }
      .join("\n")
  end

  # A kubectl that answers `get job` from an attempt counter, so an example can
  # say "fail the first Job, complete the second". `logs` returns whatever the
  # example put in logs.txt.
  def fake_kubectl(dir, failed_attempts:)
    File.write(File.join(dir, "attempts"), "0\n")
    File.write(File.join(dir, "applied.ndjson"), "")
    File.write(File.join(dir, "deployment.json"), {
      "spec" => { "template" => { "spec" => {
        "containers" => [ { "name" => "syrus-web", "image" => "old-app" } ]
      } } }
    }.to_json)
    File.write(File.join(dir, "kubectl"), <<~SH)
      #!/bin/sh
      set -eu
      if [ "$1" = "get" ] && [ "${2:-}" = "deployment" ]; then
        for arg in "$@"; do
          if [ "$arg" = "-o" ]; then
            cat "#{File.join(dir, "deployment.json")}"
          fi
        done
        exit 0
      fi
      if [ "$1" = "apply" ]; then
        cat >> "#{File.join(dir, "applied.ndjson")}"
        count=$(cat "#{File.join(dir, "attempts")}")
        echo $((count + 1)) > "#{File.join(dir, "attempts")}"
        exit 0
      fi
      if [ "$1" = "get" ] && [ "${2:-}" = "job" ]; then
        count=$(cat "#{File.join(dir, "attempts")}")
        if [ "$count" -le #{failed_attempts} ]; then
          printf '%s\\n' '{"status":{"conditions":[{"type":"Failed","status":"True"}]}}'
        else
          printf '%s\\n' '{"status":{"conditions":[{"type":"Complete","status":"True"}]}}'
        fi
        exit 0
      fi
      if [ "$1" = "logs" ]; then
        cat "#{File.join(dir, "logs.txt")}"
        exit 0
      fi
      if [ "$1" = "delete" ] || [ "$1" = "describe" ]; then
        exit 0
      fi
      echo "unexpected kubectl $*" >&2
      exit 1
    SH
    File.chmod(0o755, File.join(dir, "kubectl"))
  end

  def run_migrations(dir, attempts: 4, timeout: "1s")
    bash(<<~SH, { "PATH" => "#{dir}:#{ENV.fetch("PATH")}" })
      set -euo pipefail
      SHA=abc123
      REGISTRY=ghcr.io/example/syrus
      DB_PREPARE_TIMEOUT=#{timeout}
      DB_PREPARE_ATTEMPTS=#{attempts}
      DB_PREPARE_RETRY_DELAY=0
      #{migration_functions}
      run_database_migrations staging kubeconfig syrus
    SH
  end

  def applied_jobs(dir)
    File.read(File.join(dir, "applied.ndjson")).scan(/"kind":"Job"/).length
  end

  # Regression: the web deployment runs `db:prepare` in a db-prepare
  # initContainer on every replica at every boot, and bin/deploy runs its own
  # one-shot db:prepare Job. Rails serializes migrations with a MySQL advisory
  # lock, so the two overlapping -- a Flux reconcile mid-deploy, an eviction,
  # both replicas booting together -- kills the loser with
  # ActiveRecord::ConcurrentMigrationError and took a whole deploy down with it.
  # Losing that race means someone else is doing the work; it is not a reason to
  # stop deploying.
  describe "a migration Job that lost the advisory lock race" do
    it "retries and carries on once the lock clears" do
      Dir.mktmpdir do |dir|
        fake_kubectl(dir, failed_attempts: 1)
        File.write(File.join(dir, "logs.txt"), <<~LOG)
          bin/rails aborted!
          ActiveRecord::ConcurrentMigrationError:  (ActiveRecord::ConcurrentMigrationError)
          Cannot run migrations because another migration process is currently running.
        LOG

        out, err, status = run_migrations(dir)

        expect(status).to be_success, err
        expect(out).to include("holds the migration lock; retrying")
        expect(out).to include("database migrations complete")
        expect(applied_jobs(dir)).to eq(2)
      end
    end

    it "gives up after DB_PREPARE_ATTEMPTS rather than retrying forever" do
      Dir.mktmpdir do |dir|
        fake_kubectl(dir, failed_attempts: 99)
        File.write(File.join(dir, "logs.txt"), "ActiveRecord::ConcurrentMigrationError\n")

        _out, err, status = run_migrations(dir, attempts: 3)

        expect(status).not_to be_success
        expect(err).to include("database migration job failed")
        expect(applied_jobs(dir)).to eq(3)
      end
    end

    it "does not retry a migration that genuinely failed" do
      Dir.mktmpdir do |dir|
        fake_kubectl(dir, failed_attempts: 99)
        File.write(File.join(dir, "logs.txt"), <<~LOG)
          bin/rails aborted!
          StandardError: Mysql2::Error: Duplicate column name 'widgets'
        LOG

        _out, err, status = run_migrations(dir)

        expect(status).not_to be_success
        expect(err).to include("database migration job failed")
        expect(err).to include("Duplicate column name")
        # One attempt only: a broken migration is not going to fix itself.
        expect(applied_jobs(dir)).to eq(1)
      end
    end

    # "did not complete before 10m" about a Job that died in 40 seconds sends
    # the operator hunting a hang that never happened.
    it "calls a timeout a timeout and a failure a failure" do
      Dir.mktmpdir do |dir|
        fake_kubectl(dir, failed_attempts: 0)
        File.write(File.join(dir, "logs.txt"), "")
        # Never-completing job: `get job` reports neither condition.
        File.write(File.join(dir, "kubectl"), File.read(File.join(dir, "kubectl"))
          .sub('{"status":{"conditions":[{"type":"Complete","status":"True"}]}}', '{"status":{}}'))

        _out, err, status = run_migrations(dir, timeout: "1s")

        expect(status).not_to be_success
        expect(err).to include("did not complete before 1s")
        expect(err).not_to include("database migration job failed")
        expect(applied_jobs(dir)).to eq(1)
      end
    end
  end

  it "applies migrations before changing any live workload image" do
    migrate_at = deploy.index('run_database_migrations "$label"')
    pin_at = deploy.index('pin_live_images "$label"')

    expect(migrate_at).not_to be_nil
    expect(pin_at).not_to be_nil
    expect(migrate_at).to be < pin_at,
      "new workers must not consume work before the new image's migrations finish"
  end

  it "restores Flux's previous image overrides before resuming when migrations fail" do
    Dir.mktmpdir do |dir|
      log = File.join(dir, "kubectl.log")
      functions = %w[
        cleanup_rollout_controls rollout flux_kustomization_exists flux_resume_now
        flux_pin_desired_images flux_desired_images_snapshot_patch
        flux_restore_desired_images flux_desired_images_patch flux_request_reconcile
      ].map { |name| deploy[/^#{name}\(\) \{.*?\n\}/m] }.join("\n")

      _out, _err, status = bash(<<~SH)
        set -euo pipefail
        SHA=new-sha
        REGISTRY=ghcr.io/example/syrus
        WORKER_DEV_REGISTRY=ghcr.io/example/syrus-worker-dev
        PLUGIN_REGISTRIES=()
        FLUX_NAMESPACE=flux-system
        FLUX_KUSTOMIZATION=apps
        FLUX_IMAGE_FIELD_MANAGER=flux-client-side-apply
        ACTIVE_FLUX_KUBECONFIG=""
        ACTIVE_FLUX_LABEL=""
        ACTIVE_FLUX_IMAGES_SNAPSHOT=""
        ACTIVE_FLUX_SUSPENDED_BY_DEPLOY=false
        ACTIVE_BACKUP_KUBECONFIG=""
        ACTIVE_PREPULL_KUBECONFIG=""
        ACTIVE_DB_PREPARE_KUBECONFIG=""
        DEPLOYMENTS=(deployment/syrus-web)
        PINNED_PLUGIN_WORKLOADS=()
        #{functions}
        kubectl() {
          printf '%s\n' "$*" >> #{Shellwords.escape(log)}
          if [[ " $* " == *" -o json "* ]]; then
            printf '%s\n' '{"spec":{"images":[{"name":"ghcr.io/example/syrus","newTag":"old-sha"}]}}'
          fi
        }
        flux_suspend_with_watchdog() {
          ACTIVE_FLUX_KUBECONFIG="$1"
          ACTIVE_FLUX_LABEL="$2"
          ACTIVE_FLUX_SUSPENDED_BY_DEPLOY=true
        }
        configure_flux_suspend_ttl() { :; }
        suspend_mysql_backup() { :; }
        ensure_mise_cache() { :; }
        prepull_worker_image() { :; }
        run_database_migrations() { return 1; }
        pin_live_images() { :; }
        wait_for_rollout_target() { :; }
        verify_sha() { :; }
        verify_worker_native_toolchain() { :; }
        resume_mysql_backup() { :; }
        delete_db_prepare_job() { :; }
        delete_prepull_daemonset() { :; }
        verify_flux_desired_images() { :; }
        trap cleanup_rollout_controls EXIT
        rollout staging kubeconfig syrus
      SH

      expect(status).not_to be_success
      commands = File.readlines(log, chomp: true)
      new_pin = commands.index { |command| command.include?('new-sha') }
      restored_pin = commands.index { |command| command.include?('old-sha') }
      resume = commands.index { |command| command.include?('{"spec":{"suspend":false}}') }

      expect(new_pin).not_to be_nil
      expect(restored_pin).to be > new_pin
      expect(resume).to be > restored_pin
      expect(commands.count { |command| command.include?('new-sha') }).to eq(1)
    end
  end

  it "runs migrations from the newly built app image" do
    helper = deploy[/^apply_and_wait_db_prepare_job\(\) \{.*?\n\}/m]

    expect(helper).to include('DB_PREPARE_IMAGE="${REGISTRY}:${SHA}"')
    expect(helper).to include('"command"] = [ "./bin/rails" ]')
    expect(helper).to include('"args"] = [ "db:prepare" ]')
    expect(helper).to include('"activeDeadlineSeconds" => Integer(ENV.fetch("DB_PREPARE_DEADLINE_SECONDS"))')
    expect(helper).to include('wait_for_db_prepare_job "$kubeconfig" "$namespace" "$job_name"')
  end

  it "builds a one-shot migration Job from the web deployment environment" do
    deployment = {
      "spec" => {
        "template" => {
          "spec" => {
            "serviceAccountName" => "syrus-web",
            "imagePullSecrets" => [ { "name" => "registry" } ],
            "volumes" => [ { "name" => "secrets", "secret" => { "secretName" => "syrus" } } ],
            "initContainers" => [
              {
                "name" => "db-prepare",
                "image" => "old-app",
                "envFrom" => [ { "secretRef" => { "name" => "syrus-env" } } ],
                "volumeMounts" => [ { "name" => "secrets", "mountPath" => "/run/secrets" } ],
                "readinessProbe" => { "exec" => { "command" => [ "false" ] } }
              }
            ],
            "containers" => [
              {
                "name" => "syrus-web",
                "image" => "old-app",
                "ports" => [ { "containerPort" => 3000 } ],
                "command" => [ "./bin/thrust" ],
                "args" => [ "./bin/rails", "server" ]
              }
            ]
          }
        }
      }
    }

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "deployment.json"), deployment.to_json)
      File.write(File.join(dir, "applied.json"), "")
      File.write(File.join(dir, "kubectl"), <<~SH)
        #!/bin/sh
        set -eu
        if [ "$1" = "get" ] && [ "$2" = "deployment" ]; then
          for arg in "$@"; do
            if [ "$arg" = "-o" ]; then
              cat "#{File.join(dir, "deployment.json")}"
            fi
          done
          exit 0
        fi
        if [ "$1" = "get" ] && [ "$2" = "job" ]; then
          printf '%s\\n' '{"status":{"conditions":[{"type":"Complete","status":"True"}]}}'
          exit 0
        fi
        if [ "$1" = "apply" ]; then
          cat > "#{File.join(dir, "applied.json")}"
          exit 0
        fi
        if [ "$1" = "delete" ]; then
          exit 0
        fi
        echo "unexpected kubectl $*" >&2
        exit 1
      SH
      File.chmod(0o755, File.join(dir, "kubectl"))
      _out, err, status = bash(<<~SH, { "PATH" => "#{dir}:#{ENV.fetch("PATH")}" })
        set -euo pipefail
        SHA=abc123
        REGISTRY=ghcr.io/example/syrus
        DB_PREPARE_TIMEOUT=1s
        DB_PREPARE_ATTEMPTS=1
        DB_PREPARE_RETRY_DELAY=0
        #{migration_functions}
        run_database_migrations staging kubeconfig syrus
      SH

      expect(status).to be_success, err
      manifest = JSON.parse(File.read(File.join(dir, "applied.json")))
      spec = manifest.fetch("spec").fetch("template").fetch("spec")
      expect(spec.fetch("containers").size).to eq(1)
      container = spec.fetch("containers").first

      expect(manifest.fetch("kind")).to eq("Job")
      expect(manifest.fetch("spec").fetch("activeDeadlineSeconds")).to eq(1)
      expect(spec.fetch("restartPolicy")).to eq("Never")
      expect(spec.fetch("serviceAccountName")).to eq("syrus-web")
      expect(spec.fetch("imagePullSecrets")).to eq([ { "name" => "registry" } ])
      expect(spec.fetch("volumes")).to eq([ { "name" => "secrets", "secret" => { "secretName" => "syrus" } } ])
      expect(container).to include(
        "name" => "db-prepare",
        "image" => "ghcr.io/example/syrus:abc123",
        "command" => [ "./bin/rails" ],
        "args" => [ "db:prepare" ],
        "envFrom" => [ { "secretRef" => { "name" => "syrus-env" } } ],
        "volumeMounts" => [ { "name" => "secrets", "mountPath" => "/run/secrets" } ]
      )
      expect(container).not_to have_key("readinessProbe")
    end
  end
end
