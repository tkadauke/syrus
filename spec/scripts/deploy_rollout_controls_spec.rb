require "spec_helper"
require "open3"

RSpec.describe "bin/deploy rollout controls" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:deploy) { File.read(File.join(root, "bin/deploy")) }

  def helper(name)
    deploy[/^#{Regexp.escape(name)}\(\) \{.*?^\}/m] or raise "missing #{name}"
  end

  def bash(script, env = {})
    Open3.capture3(env, "bash", "-c", script, chdir: root)
  end

  it "parses plain and compound durations and rejects malformed values" do
    function = helper("duration_to_seconds")
    out, err, status = bash(<<~SH)
      set -euo pipefail
      #{function}
      duration_to_seconds 90
      duration_to_seconds 1m30s
      duration_to_seconds 1h30m
      ! duration_to_seconds 1h30x
    SH

    expect(status).to be_success, err
    expect(out.lines.map(&:chomp)).to eq(%w[90 90 5400])
    expect(err).to include("invalid duration '1h30x'")
  end

  it "paces immediately failing rollout status calls" do
    out, err, status = bash(<<~SH)
      set -euo pipefail
      ROLLOUT_TIMEOUT=2s
      ROLLOUT_STALL_DIAGNOSE_INTERVAL=1s
      ROLLOUT_MIN_POLL_INTERVAL=1s
      ROLLOUT_VERBOSE_DIAGNOSTICS=false
      calls=0
      trap 'echo CALLS=$calls' EXIT
      #{helper("duration_to_seconds")}
      diagnose_rollout_target_full() { :; }
      kubectl() { calls=$((calls + 1)); return 1; }
      #{helper("wait_for_rollout_target")}
      wait_for_rollout_target staging kubeconfig namespace deployment/app
    SH

    expect(status).not_to be_success
    expect(out[/CALLS=(\d+)/, 1].to_i).to be_between(2, 4)
    expect(err).to include("still not rolled out after 2s")
  end

  it "fails fast when Kubernetes reports the progress deadline was exceeded" do
    out, err, status = bash(<<~SH)
      set -euo pipefail
      ROLLOUT_TIMEOUT=30s
      ROLLOUT_STALL_DIAGNOSE_INTERVAL=10s
      ROLLOUT_MIN_POLL_INTERVAL=1s
      ROLLOUT_VERBOSE_DIAGNOSTICS=false
      #{helper("duration_to_seconds")}
      diagnose_rollout_target_full() { :; }
      kubectl() { echo 'error: deployment exceeded its progress deadline'; return 1; }
      #{helper("wait_for_rollout_target")}
      wait_for_rollout_target staging kubeconfig namespace deployment/app
    SH

    expect(status).not_to be_success
    expect(out).to be_empty
    expect(err.scan("exceeded its progress deadline").size).to eq(2)
    expect(err).not_to include("still rolling out")
  end

  it "leaves an operator-suspended backup CronJob suspended" do
    out, err, status = bash(<<~SH)
      set -euo pipefail
      MYSQL_BACKUP_CRONJOB=syrus-mysql-backup
      ACTIVE_BACKUP_KUBECONFIG=
      ACTIVE_BACKUP_NAMESPACE=
      ACTIVE_BACKUP_LABEL=
      ACTIVE_BACKUP_SUSPENDED_BY_DEPLOY=false
      kubectl() {
        case " $* " in
          *" -o jsonpath="*) echo true ;;
          *" patch "*) echo PATCHED ;;
        esac
      }
      drain_mysql_backup_pods() { :; }
      #{helper("suspend_mysql_backup")}
      #{helper("resume_mysql_backup")}
      suspend_mysql_backup kubeconfig namespace staging
      resume_mysql_backup kubeconfig namespace staging
    SH

    expect(status).to be_success, err
    expect(out).to include("was already suspended")
    expect(out).not_to include("PATCHED")
  end

  it "does not schedule a watchdog or resume operator-suspended Flux" do
    out, err, status = bash(<<~SH)
      set -euo pipefail
      FLUX_NAMESPACE=flux-system
      FLUX_KUSTOMIZATION=apps
      FLUX_SUSPEND_TTL=1200
      ACTIVE_FLUX_KUBECONFIG=
      ACTIVE_FLUX_LABEL=
      ACTIVE_FLUX_SUSPENDED_BY_DEPLOY=false
      flux_kustomization_exists() { return 0; }
      kubectl() { echo true; }
      ensure_watchdog_rbac() { echo RBAC; }
      schedule_resume_watchdog() { echo WATCHDOG; }
      flux_request_reconcile() { echo RECONCILE; }
      #{helper("flux_suspend_with_watchdog")}
      #{helper("flux_resume_now")}
      flux_suspend_with_watchdog kubeconfig staging
      flux_resume_now kubeconfig staging
    SH

    expect(status).to be_success, err
    expect(out).to include("was already suspended")
    expect(out).not_to include("RBAC")
    expect(out).not_to include("WATCHDOG")
    expect(out).not_to include("RECONCILE")
  end
end
