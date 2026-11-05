require "spec_helper"
require "open3"
require "tmpdir"

# `--dry-run` is the conformance oracle for changing how deploys work: run two
# implementations against the same cluster state, diff the command streams. It
# is only worth that if it provably changes nothing, so these examples assert
# the negative -- that a write never reached the fake binary -- rather than
# just that something got printed.
RSpec.describe "bin/deploy --dry-run" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:deploy) { File.read(File.join(root, "bin/deploy")) }

  def dry_run_functions
    %w[dry_run_open_stream dry_run_emit dry_run_skips_wait kubectl docker sleep].map do |name|
      deploy[/^#{name}\(\) \{.*?\n\}/m] or raise "#{name} not found in bin/deploy"
    end.join("\n")
  end

  # Records every invocation that actually reached the binary, so an example
  # can assert a command was not merely printed but genuinely skipped.
  def fake_binaries(dir)
    %w[kubectl docker sleep].each do |name|
      path = File.join(dir, name)
      File.write(path, <<~SH)
        #!/bin/sh
        printf '%s\\n' "#{name} $*" >> "#{File.join(dir, "invoked.log")}"
        if [ "$1" = "get" ]; then printf 'REAL_READ_OUTPUT\\n'; fi
        exit 0
      SH
      File.chmod(0o755, path)
    end
    File.write(File.join(dir, "invoked.log"), "")
  end

  def run(script, dry_run:, dir:)
    preamble = <<~SH
      set -uo pipefail
      PATH="#{dir}:$PATH"
      DRY_RUN=#{dry_run}
      #{deploy[/^KUBECTL_KNOWN_VERBS=.*$/]}
      #{deploy[/^KUBECTL_READ_VERBS=.*$/]}
      #{dry_run_functions}
      dry_run_open_stream
    SH
    stdout, stderr, status = Open3.capture3("bash", "-c", "#{preamble}\n#{script}", chdir: root)
    [ stdout, stderr, status, File.read(File.join(dir, "invoked.log")) ]
  end

  around do |example|
    Dir.mktmpdir do |dir|
      fake_binaries(dir)
      @dir = dir
      example.run
    end
  end

  it "prints a mutating kubectl without running it" do
    stdout, _err, status, invoked = run("kubectl apply -f manifest.yaml -n syrus", dry_run: true, dir: @dir)

    expect(status).to be_success
    expect(stdout).to include("DRYRUN kubectl apply -f manifest.yaml -n syrus")
    expect(invoked).to be_empty
  end

  it "still runs reads, because manifests are derived from live state" do
    stdout, _err, _status, invoked = run("kubectl get deployment syrus-web -o json", dry_run: true, dir: @dir)

    expect(stdout).to include("REAL_READ_OUTPUT")
    expect(stdout).not_to include("DRYRUN")
    expect(invoked).to include("kubectl get deployment syrus-web -o json")
  end

  it "finds the verb past leading flags" do
    stdout, _err, _status, invoked = run("kubectl -n syrus --context prod delete job/foo", dry_run: true, dir: @dir)

    expect(stdout).to include("DRYRUN kubectl -n syrus --context prod delete job/foo")
    expect(invoked).to be_empty
  end

  # Without draining, the upstream producer dies of SIGPIPE and pipefail takes
  # the whole deploy with it -- a dry run that crashes where a real deploy
  # succeeds is useless as an oracle.
  it "drains stdin for a write fed from a pipeline" do
    stdout, _err, status, invoked = run(
      "printf 'apiVersion: v1\\n' | kubectl apply -f - -n syrus; echo \"exit=$?\"",
      dry_run: true, dir: @dir
    )

    expect(status).to be_success
    expect(stdout).to include("exit=0")
    expect(invoked).to be_empty
  end

  it "prints mutating docker commands without running them" do
    stdout, _err, _status, invoked = run("docker push ghcr.io/example/app:abc123", dry_run: true, dir: @dir)

    expect(stdout).to include("DRYRUN docker push ghcr.io/example/app:abc123")
    expect(invoked).to be_empty
  end

  it "returns from backoffs immediately so a dry run is worth running" do
    _stdout, _err, status, invoked = run("sleep 30", dry_run: true, dir: @dir)

    expect(status).to be_success
    expect(invoked).to be_empty
  end

  it "passes everything through when not dry running" do
    stdout, _err, _status, invoked = run(
      "kubectl apply -f manifest.yaml; docker push example:tag; sleep 0", dry_run: false, dir: @dir
    )

    expect(stdout).not_to include("DRYRUN")
    expect(invoked).to include("kubectl apply -f manifest.yaml")
    expect(invoked).to include("docker push example:tag")
  end

  it "accepts the flag and implies --skip-build" do
    expect(deploy).to match(/--dry-run\)\s+DRY_RUN=true;\s+SKIP_BUILD=true/)

    stdout, _err, status = Open3.capture3("bash", File.join(root, "bin/deploy"), "--dry-run", "--help", chdir: root)

    expect(status).to be_success
    expect(stdout).to include("--dry-run")
  end

  # The consequential default. An unrecognised verb -- a kubectl subcommand
  # added later, a plugin -- must be assumed to mutate, or the first new verb
  # someone uses silently escapes the dry run.
  it "treats an unrecognised verb as a write" do
    stdout, _err, _status, invoked = run("kubectl some-future-verb thing -n syrus", dry_run: true, dir: @dir)

    expect(stdout).to include("DRYRUN kubectl some-future-verb thing -n syrus")
    expect(invoked).to be_empty
  end

  it "skips every docker invocation, reads included" do
    stdout, _err, _status, invoked = run(
      "docker buildx imagetools inspect example:tag; docker build .", dry_run: true, dir: @dir
    )

    expect(stdout).to include("DRYRUN docker buildx imagetools inspect example:tag")
    expect(stdout).to include("DRYRUN docker build .")
    expect(invoked).to be_empty
  end

  # The bug a real dry run exposed: the Flux and cronjob suspend patches end in
  # `>/dev/null`, so emitting on stdout dropped precisely the writes the stream
  # exists to record.
  it "still records a write whose call site discards stdout" do
    stdout, _err, _status, invoked = run(
      "kubectl patch kustomization apps --type merge -p '{}' >/dev/null", dry_run: true, dir: @dir
    )

    expect(stdout).to include("DRYRUN kubectl patch kustomization apps --type merge -p {}")
    expect(invoked).to be_empty
  end

  it "captures the stream to a file when asked, for diffing" do
    Dir.mktmpdir do |out|
      path = File.join(out, "stream.txt")
      _stdout, _err, status, _invoked = run(
        "DRY_RUN_STREAM=#{path} dry_run_open_stream; kubectl apply -f x.yaml >/dev/null",
        dry_run: true, dir: @dir
      )

      expect(status).to be_success
      expect(File.read(path)).to eq("DRYRUN kubectl apply -f x.yaml\n")
    end
  end

  describe "waits and verifications" do
    # These short-circuits return success, so firing one outside a dry run
    # would silently pass a rollout that never converged. The predicate must
    # be false whenever DRY_RUN is not exactly true.
    it "only skips when dry running" do
      %w[true false "" no 1].each do |value|
        script = "DRY_RUN=#{value}\n#{deploy[/^dry_run_skips_wait\(\) \{.*?\n\}/m]}\n" \
                 "if dry_run_skips_wait; then echo SKIP; else echo RUN; fi"
        stdout, _err, _status = Open3.capture3("bash", "-c", script, chdir: root)
        expect(stdout.strip).to eq(value == "true" ? "SKIP" : "RUN"), "DRY_RUN=#{value}"
      end
    end

    # A wait that polls for a resource the dry run never created would spin
    # until its own deadline; a verification would compare against pods that
    # were never rolled out and fail a correct dry run.
    it "guards every wait and post-rollout verification" do
      %w[
        wait_for_db_prepare_job wait_for_rollout_target drain_mysql_backup_pods
        verify_sha verify_coworker_confinement verify_flux_desired_images
      ].each do |name|
        body = deploy[/^#{name}\(\) \{.*?\n\}/m] or raise "#{name} not found"
        expect(body).to include("dry_run_skips_wait && return 0"), "#{name} is unguarded"
      end
    end
  end

  it "guards the git tag and push behind the flag" do
    expect(deploy).to match(/dry_run_emit git tag -f staging/)
    expect(deploy).to match(/dry_run_emit git push --force origin production/)
  end
end
