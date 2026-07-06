# frozen_string_literal: true

require "spec_helper"

# install.sh owns the Docker install machine interface (NDJSON events on
# stdout, step ids, exit-code classes); install.ps1 is its Windows port and
# must speak the identical protocol so the desktop app's installer driver
# stays platform-agnostic. PowerShell isn't available on the mac/linux CI
# hosts, so this is a static parity contract: read both scripts and pin every
# load-bearing string they must share. A failure here means one installer
# changed without the other (or the protocol broke in both).
RSpec.describe "install.ps1 parity with install.sh" do
  let(:repo_root) { File.expand_path("../..", __dir__) }
  let(:sh) { File.read(File.join(repo_root, "install.sh"), encoding: "UTF-8") }
  let(:ps1) { File.read(File.join(repo_root, "install.ps1"), encoding: "UTF-8") }

  it "emits the same NDJSON event vocabulary" do
    sh_events = sh.scan(/\\"event\\":\\"(\w+)\\"/).flatten.uniq.sort
    ps_events = ps1.scan(/\bevent = "(\w+)"/).flatten.uniq.sort
    expect(sh_events).to eq(%w[done error log start step])
    expect(ps_events).to eq(sh_events)
  end

  it "walks the same step ids in both scripts" do
    sh_steps = sh.scan(/^\s*emit_step (\w+)/).flatten.uniq.sort
    ps_steps = ps1.scan(/Emit-Step "(\w+)"/).flatten.uniq.sort
    expect(sh_steps).to eq(
      %w[compose_resolve env_check env_generate health image_pull
         runtime_check runtime_install runtime_start stack_up].sort
    )
    expect(ps_steps).to eq(sh_steps)
  end

  it "classifies failures with the same exit codes" do
    ps_codes = ps1.scan(/Fail "[^"]*" (\d+)/).flatten.map(&:to_i).uniq
    [2, 10, 11, 12, 20, 30, 31, 32, 40, 41].each do |code|
      expect(sh).to match(/ #{code}$/), "install.sh: expected a die call with exit code #{code}"
      expect(ps_codes).to include(code), "install.ps1: expected a Fail call with exit code #{code}"
    end
  end

  it "reproduces the sequencing quirks the GUI checklist depends on" do
    # Runtime already up: runtime_check start, runtime_check ok, and
    # runtime_start resolved as skipped so its row never dangles as pending.
    expect(sh).to include("emit_step runtime_start skipped")
    expect(ps1).to include('Emit-Step "runtime_start" "skipped"')
    expect(sh).to include('emit_step runtime_check ok "runtime not ready yet"')
    expect(ps1).to include('Emit-Step "runtime_check" "ok" "runtime not ready yet"')
    # runtime_install starts only right before the exit-10 death.
    expect(sh).to include("emit_step runtime_install start")
    expect(ps1).to include('Emit-Step "runtime_install" "start"')
    # An existing .env skips generation instead of re-minting secrets.
    expect(sh).to include("emit_step env_generate skipped")
    expect(ps1).to include('Emit-Step "env_generate" "skipped"')
  end

  it "recommends only Docker Desktop when no runtime exists (Podman compose is unsupported)" do
    # The guided onboarding decided Docker-Desktop-only for Windows
    # (windows_scaffold_spec pins RuntimeSetup); the installer's exit-10
    # copy must not contradict it. Detecting/starting an ALREADY-installed
    # Podman Desktop with the Docker socket is still fine — this pins only
    # the recommendation.
    exit10 = ps1[/Fail "No container runtime found[^"]*"/]
    expect(exit10).to include("docker.com/products/docker-desktop")
    expect(exit10).not_to include("Podman")
  end

  it "carries the image ref as the image_pull start detail" do
    expect(sh).to include('emit_step image_pull start "$IMAGE"')
    expect(ps1).to include('Emit-Step "image_pull" "start" $image')
  end

  it "shares the verbatim log lines the desktop app keys on" do
    [
      "pull failed; using the local image copy",
      "pull attempt",
      "failed; retrying",
      "SYRUS_IMAGE pin updated:",
      "<empty>"
    ].each do |line|
      expect(sh).to include(line), "install.sh: missing #{line.inspect}"
      expect(ps1).to include(line), "install.ps1: missing #{line.inspect}"
    end
  end

  it "shares the error-message fragments the GUI error screens key on" do
    [
      "undecryptable",
      "denied (stale login, private package, or unpublished tag)",
      "docker logout ghcr.io",
      "does not exist in the registry",
      "didn't become healthy",
      "docker compose up failed",
      "syrus_syrus-data"
    ].each do |fragment|
      expect(sh).to include(fragment), "install.sh: missing #{fragment.inspect}"
      expect(ps1).to include(fragment), "install.ps1: missing #{fragment.inspect}"
    end
  end

  it "orders pull-failure classification the same way: denied wins over not-found" do
    # GHCR's anonymous-denied message mentions both "denied" and "does not
    # exist" - the denied branch must be checked first in both scripts.
    [sh, ps1].each do |text|
      denied = text.index("denied (stale login, private package, or unpublished tag)")
      missing = text.index("does not exist in the registry")
      expect(denied).to be < missing
    end
  end

  it "classifies a broken credential helper as 31 with logout guidance, before the denied branch" do
    # A stale keychain entry fails with "error getting credentials" — a message
    # with neither "denied" nor "unauthorized" in it, which used to fall through
    # to the misleading exit-30 "network problem" branch. Docker sends stored
    # ghcr.io credentials on every pull and GHCR rejects an expired token even
    # for PUBLIC images, so the fix is `docker logout ghcr.io`, not a login.
    [sh, ps1].each do |text|
      helper = text.index("error getting credentials")
      denied = text.index("denied (stale login, private package, or unpublished tag)")
      expect(helper).not_to be_nil
      expect(helper).to be < denied
    end
    expect(sh).to include("stored Docker credentials for the registry are broken")
    expect(ps1).to include("stored Docker credentials for the registry are broken")
  end

  it "defaults to the same image, project name, knobs, and --image charset" do
    [
      "ghcr.io/tkadauke/syrus-backend:latest",
      "COMPOSE_PROJECT_NAME",
      "SYRUS_HEALTH_POLLS",
      "SYRUS_PULL_RETRY_DELAY",
      "A-Za-z0-9._/:@-"
    ].each do |token|
      expect(sh).to include(token), "install.sh: missing #{token.inspect}"
      expect(ps1).to include(token), "install.ps1: missing #{token.inspect}"
    end
  end

  it "generates the same secrets from the same template" do
    %w[
      SECRET_KEY_BASE=
      ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=
      ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=
      ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=
      compose.env.example
    ].each do |token|
      expect(sh).to include(token), "install.sh: missing #{token.inspect}"
      expect(ps1).to include(token), "install.ps1: missing #{token.inspect}"
    end
  end

  it "documents every GUI flag and the exit codes in both help texts" do
    %w[--docker --non-interactive --json --target-dir --skip-runtime-install --image --port].each do |flag|
      expect(sh).to include(flag)
      expect(ps1).to include(flag)
    end
    expect(sh).to include("Exit codes:")
    expect(ps1).to include("Exit codes:")
  end

  it "gates success on the Rails health endpoint in both scripts" do
    expect(sh).to include("/up")
    expect(ps1).to include("/up")
  end

  describe "PowerShell 5.1 safety" do
    it "writes .env as BOM-less UTF-8 (5.1 defaults would corrupt the encryption keys)" do
      expect(ps1).to include("UTF8Encoding($false)")
      expect(ps1).to include("WriteAllText")
    end

    it "keeps stdout protocol-only: console writers plus compact JSON, never host writers" do
      expect(ps1).to include("[Console]::Out.WriteLine")
      expect(ps1).to include("[Console]::Error.WriteLine")
      expect(ps1).to include("ConvertTo-Json -Compress")
      expect(ps1).not_to include("Write-Host")
    end

    it "sets a UTF-8 console encoding before emitting protocol output" do
      expect(ps1).to include("[Console]::OutputEncoding")
    end

    it "avoids pwsh-7-only APIs while keeping CSPRNG secrets" do
      expect(ps1).not_to include("ToHexString")
      expect(ps1).to include("RandomNumberGenerator")
    end

    it "stays pure ASCII because PS 5.1 parses BOM-less files with the ANSI codepage" do
      non_ascii = ps1.bytes.reject { |b| b < 128 }
      expect(non_ascii).to be_empty
    end

    it "starts an installed-but-stopped Docker Desktop and hardens PATH for GUI spawns" do
      expect(ps1).to include("Docker Desktop.exe")
      expect(ps1).to include("Start-Process")
      expect(ps1).to include('Docker\Docker\resources\bin')
    end

    it "polls health with basic parsing and a bounded timeout" do
      expect(ps1).to include("Invoke-WebRequest -UseBasicParsing -TimeoutSec 2")
    end

    it "anchors flag validation with \\z (.NET's $ accepts a trailing newline bash rejects)" do
      expect(ps1).to include('"^[A-Za-z0-9._/:@-]+\z"')
      expect(ps1).to include('"^[0-9]+\z"')
    end
  end
end
