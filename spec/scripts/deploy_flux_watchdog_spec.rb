require "spec_helper"
require "open3"

RSpec.describe "bin/deploy Flux watchdog" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:deploy) { File.read(File.join(root, "bin/deploy")) }
  let(:env_example) { File.read(File.join(root, ".env.example")) }

  def bash(script)
    Open3.capture3("bash", "-c", script, chdir: root)
  end

  def helper(name)
    deploy[/^#{name}\(\) \{.*?^\}/m]
  end

  it "derives the watchdog TTL from every bounded rollout phase" do
    out, err, status = bash(<<~SH)
      set -euo pipefail
      PREPULL=1
      PREPULL_TIMEOUT=12m
      DB_PREPARE_TIMEOUT=10m
      ROLLOUT_TIMEOUT=15m
      FLUX_SUSPEND_SLACK=5m
      #{helper("duration_to_seconds")}
      #{helper("flux_suspend_budget_seconds")}
      flux_suspend_budget_seconds 4
    SH

    expect(status).to be_success, err
    expect(out.strip).to eq("6120")
  end

  it "omits the pre-pull timeout when pre-pull is disabled" do
    out, err, status = bash(<<~SH)
      set -euo pipefail
      PREPULL=0
      PREPULL_TIMEOUT=12m
      DB_PREPARE_TIMEOUT=10m
      ROLLOUT_TIMEOUT=15m
      FLUX_SUSPEND_SLACK=5m
      #{helper("duration_to_seconds")}
      #{helper("flux_suspend_budget_seconds")}
      flux_suspend_budget_seconds 1
    SH

    expect(status).to be_success, err
    expect(out.strip).to eq("2700")
  end

  it "warns when an explicit TTL is shorter than the computed budget" do
    out, err, status = bash(<<~SH)
      set -euo pipefail
      PREPULL=1
      PREPULL_TIMEOUT=1s
      DB_PREPARE_TIMEOUT=2s
      ROLLOUT_TIMEOUT=3s
      FLUX_SUSPEND_SLACK=4s
      FLUX_SUSPEND_TTL=12
      FLUX_SUSPEND_TTL_OVERRIDE=12
      #{helper("duration_to_seconds")}
      #{helper("flux_suspend_budget_seconds")}
      #{helper("configure_flux_suspend_ttl")}
      configure_flux_suspend_ttl staging 1
      printf '%s' "$FLUX_SUSPEND_TTL"
    SH

    expect(status).to be_success, err
    expect(out).to eq("12")
    expect(err).to include("below the computed deploy budget of 13s for 1 rollout target(s)")
  end

  it "uses the computed budget when no TTL override is provided" do
    out, err, status = bash(<<~SH)
      set -euo pipefail
      PREPULL=0
      PREPULL_TIMEOUT=1s
      DB_PREPARE_TIMEOUT=2s
      ROLLOUT_TIMEOUT=3s
      FLUX_SUSPEND_SLACK=4s
      FLUX_SUSPEND_TTL_OVERRIDE=""
      FLUX_SUSPEND_TTL=""
      #{helper("duration_to_seconds")}
      #{helper("flux_suspend_budget_seconds")}
      #{helper("configure_flux_suspend_ttl")}
      configure_flux_suspend_ttl staging 1
      first="$FLUX_SUSPEND_TTL"
      configure_flux_suspend_ttl production 2
      printf '%s %s' "$first" "$FLUX_SUSPEND_TTL"
    SH

    expect(status).to be_success, err
    expect(out).to eq("12 15")
    expect(deploy).to include('configure_flux_suspend_ttl "$label" "$(( ${#targets[@]} + plugin_target_count ))"')
    expect(deploy).to include("activeDeadlineSeconds: $((FLUX_SUSPEND_TTL + 120))")
  end

  it "does not opt template-based deployments into a short fixed TTL" do
    expect(env_example).to include(
      "FLUX_SUSPEND_TTL= # Optional fixed watchdog TTL in seconds; unset derives it from all deploy phase budgets."
    )
    expect(env_example).to include("FLUX_SUSPEND_SLACK=5m")
    expect(env_example).not_to match(/^FLUX_SUSPEND_TTL=\d+/)
  end
end
