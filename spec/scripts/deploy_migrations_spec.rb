require "spec_helper"
require "json"
require "open3"
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

  it "does not pin Flux to the new image when migrations fail" do
    rollout = deploy[/^rollout\(\) \{.*?\n\}/m]

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "kubectl"), <<~SH)
        #!/bin/sh
        exit 0
      SH
      File.chmod(0o755, File.join(dir, "kubectl"))

      out, err, status = bash(<<~SH, { "PATH" => "#{dir}:#{ENV.fetch("PATH")}" })
        set -euo pipefail
        DEPLOYMENTS=(deployment/syrus-web)
        PINNED_PLUGIN_WORKLOADS=()
        #{rollout}
        flux_suspend_with_watchdog() { echo suspend; }
        suspend_mysql_backup() { echo suspend-backup; }
        ensure_mise_cache() { echo mise-cache; }
        prepull_worker_image() { echo prepull; }
        run_database_migrations() { echo migration-failed; return 1; }
        pin_live_images() { echo pin-live; }
        wait_for_rollout_target() { echo wait-rollout; }
        verify_sha() { echo verify-sha; }
        verify_worker_native_toolchain() { echo verify-toolchain; }
        resume_mysql_backup() { echo resume-backup; }
        flux_pin_desired_images() { echo pin-flux; }
        flux_resume_now() { echo resume-flux; }
        verify_flux_desired_images() { echo verify-flux; }
        rollout staging kubeconfig syrus
      SH

      expect(status).not_to be_success
      expect(err).to be_empty
      expect(out).to include("migration-failed")
      expect(out).not_to include("pin-live")
      expect(out).not_to include("pin-flux")
      expect(out).not_to include("resume-flux")
    end
  end

  it "pins Flux only after the rollout has been verified and backups resumed" do
    rollout = deploy[/^rollout\(\) \{.*?\n\}/m]

    expect(rollout.index('flux_pin_desired_images "$kubeconfig" "$label"')).to be >
      rollout.index('verify_worker_native_toolchain "$label" "$kubeconfig" "$namespace"')
    expect(rollout.index('flux_pin_desired_images "$kubeconfig" "$label"')).to be >
      rollout.index('resume_mysql_backup "$kubeconfig" "$namespace" "$label"')
    expect(rollout.index('flux_pin_desired_images "$kubeconfig" "$label"')).to be <
      rollout.index('flux_resume_now "$kubeconfig" "$label"')
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
