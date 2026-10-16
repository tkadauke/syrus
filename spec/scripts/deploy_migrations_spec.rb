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
        }
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
    helper = deploy[/^run_database_migrations\(\) \{.*?\n\}/m]

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
      function = deploy[/^run_database_migrations\(\) \{.*?\n\}/m] + "\n" +
        deploy[/^wait_for_db_prepare_job\(\) \{.*?\n\}/m] + "\n" +
        deploy[/^duration_to_seconds\(\) \{.*?\n\}/m] + "\n" +
        deploy[/^delete_db_prepare_job\(\) \{.*?\n\}/m]

      _out, err, status = bash(<<~SH, { "PATH" => "#{dir}:#{ENV.fetch("PATH")}" })
        set -euo pipefail
        SHA=abc123
        REGISTRY=ghcr.io/example/syrus
        DB_PREPARE_TIMEOUT=1s
        #{function}
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
