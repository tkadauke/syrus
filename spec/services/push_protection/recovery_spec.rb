require "rails_helper"
require "tmpdir"

RSpec.describe PushProtection::Recovery do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "running") }
  let(:workflow) { Workflows::Initial.instantiate(job: job) }
  let(:dir) { Dir.mktmpdir("push-protection") }
  let(:data_root) { Dir.mktmpdir("pp-data") }
  let(:branch) { job.branch_name.presence || "syrus/job-test" }
  let(:ledger) { PushProtection::Ledger.for(workflow) }

  def sh(*args, env: {})
    out, status = Open3.capture2e(ENV.to_h.merge(env), "git", *args, chdir: dir)
    raise "git #{args.join(' ')}: #{out}" unless status.success?

    out.strip
  end

  def commit_file(path, content, msg)
    FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
    File.write(File.join(dir, path), content)
    sh("add", "-A")
    sh("commit", "-m", msg)
    sh("rev-parse", "HEAD")
  end

  def rejection(shas, paths: [ "secret.txt" ], ref: "refs/heads/#{branch}")
    findings = shas.zip(paths.cycle).map do |s, p|
      GithubPushProtection::Finding.new(secret_type: "Token", commit_sha: s, path: p, line: 1)
    end
    GithubPushProtection::Rejected.new([ "push", "x", "HEAD:#{ref}" ], 1, findings: findings, ref: ref)
  end

  attr_reader :anchor, :bad1, :bad2

  before do
    allow(WorkflowWorkspace).to receive(:data_root).and_return(Pathname.new(data_root))
    sh("init", "-q", "-b", "main")
    sh("config", "user.email", "t@example.com")
    sh("config", "user.name", "T")
    @anchor = commit_file("README.md", "hi\n", "base")
    sh("checkout", "-q", "-b", branch)
    @bad1 = commit_file("secret.txt", "TOKEN=abc\n", "add config")
    @bad2 = commit_file("other.txt", "ok\n", "more work")
    ledger.seed_anchor!(anchor)
  end

  after { FileUtils.rm_rf([ dir, data_root ]) }

  def recovery = described_class.for(workflow: workflow, workspace_path: dir, branch: branch)

  it "collapses a multi-commit rejected range into one commit atop the clean anchor" do
    outcome = recovery.handle_rejection!(rejection([ bad1 ]))

    expect(outcome).to be_repair
    expect(sh("rev-list", "--parents", "-n", "1", "HEAD").split.drop(1)).to eq([ anchor ])
    expect(sh("rev-parse", "HEAD^{tree}")).to eq(sh("rev-parse", "#{bad2}^{tree}"))
    expect(File.exist?(outcome.candidate.bundle_path)).to be(true)
    expect(ledger.data).to include("status" => "repairing", "rejected_shas" => [ bad2 ])
    expect(ledger.data["lineage"]).to include("job_id" => job.id, "workflow_id" => workflow.id)
    expect(ledger).to be_repair_active
  end

  it "accepts a tip amend and reconstructs the same authoritative commit" do
    recovery.handle_rejection!(rejection([ bad1 ]))
    File.write(File.join(dir, "secret.txt"), "TOKEN=<redacted>\n")
    sh("add", "-A")
    sh("commit", "--amend", "--no-edit", env: { "GIT_COMMITTER_DATE" => "2001-01-01T00:00:00Z" })
    amended = sh("rev-parse", "HEAD")

    outcome = recovery.verify_repair!

    expect(outcome.kind).to eq(:verified)
    final = sh("rev-parse", "HEAD")
    expect(final).not_to eq(amended) # harness-controlled metadata, not the agent's
    expect(sh("rev-list", "--parents", "-n", "1", "HEAD").split.drop(1)).to eq([ anchor ])
    expect(File.read(File.join(dir, "secret.txt"))).to include("<redacted>")

    # idempotent: reconstructing again from the reconstructed HEAD is a no-op
    expect(recovery.verify_repair!.kind).to eq(:verified)
    expect(sh("rev-parse", "HEAD")).to eq(final)
  end

  it "reconstructs an equivalent result when the agent already amended with the same metadata" do
    recovery.handle_rejection!(rejection([ bad1 ]))
    File.write(File.join(dir, "secret.txt"), "TOKEN=<redacted>\n")
    sh("add", "-A")
    sh("commit", "--amend", "--no-edit")
    expect(recovery.verify_repair!.kind).to eq(:verified)
    expect(sh("rev-list", "--count", "#{anchor}..HEAD")).to eq("1")
  end

  it "rejects history manipulation that leaves a merge or the rejected ancestry reachable" do
    recovery.handle_rejection!(rejection([ bad1 ]))
    sh("merge", "--no-ff", "-m", "merge rejected", bad2)

    outcome = recovery.verify_repair!

    expect(outcome.kind).to eq(:contract_violation)
    expect(outcome.violations.join("\n")).to include("exactly one parent").and include("must not be ancestors")
  end

  it "rejects unauthorized ref, remote, config and unrelated-file changes" do
    recovery.handle_rejection!(rejection([ bad1 ]))
    sh("branch", "stray")
    sh("remote", "add", "evil", "https://example.invalid/x.git")
    File.write(File.join(dir, "unrelated.txt"), "x\n")
    File.write(File.join(dir, "secret.txt"), "clean\n")
    sh("add", "-A")
    sh("commit", "--amend", "--no-edit")

    violations = recovery.verify_repair!.violations.join("\n")

    expect(violations).to include("refs changed").and include("remotes changed")
  end

  it "rejects unrelated file changes when topology is otherwise clean" do
    recovery.handle_rejection!(rejection([ bad1 ]))
    File.write(File.join(dir, "unrelated.txt"), "x\n")
    sh("add", "-A")
    sh("commit", "--amend", "--no-edit")

    expect(recovery.verify_repair!.violations.join("\n")).to include("Unrelated files changed: unrelated.txt")
  end

  it "stops for operator review after the bounded retry limit and keeps the evidence" do
    recovery.handle_rejection!(rejection([ bad1 ]))
    sh("commit", "--allow-empty", "-m", "extra")

    first = recovery.verify_repair!
    second = recovery.verify_repair!

    expect(first.kind).to eq(:contract_violation)
    expect(second.kind).to eq(:operator_review)
    expect(ledger.status).to eq("operator_review")
    expect(ledger.evidence["findings"]).to be_present
    expect(ledger).not_to be_repair_active
  end

  it "routes findings already in the accepted anchor to the upstream owner without rewriting" do
    outcome = recovery.handle_rejection!(rejection([ anchor ]))

    expect(outcome.kind).to eq(:upstream_contaminated)
    expect(sh("rev-parse", "HEAD")).to eq(bad2)
    expect(ledger.status).to eq("upstream_contaminated")
  end

  it "quarantines shared merge-train refs instead of rewriting them" do
    outcome = recovery.handle_rejection!(rejection([ bad1 ], ref: "refs/heads/syrus/merge-train/7"))

    expect(outcome.kind).to eq(:quarantine)
    expect(sh("rev-parse", "HEAD")).to eq(bad2)
    expect(ledger.data["route_to_job_ids"]).to eq([ job.id ])
    expect(ledger.status).to eq("quarantined")
  end

  it "never retries an identical rejected SHA" do
    recovery.handle_rejection!(rejection([ bad1 ]))
    sh("reset", "-q", "--hard", bad2)

    outcome = recovery.handle_rejection!(rejection([ bad1 ]))

    expect(outcome.kind).to eq(:operator_review)
    expect(outcome.detail).to include("identical SHA is never retried")
  end

  it "advances the clean anchor only after GitHub accepts the push" do
    recovery.handle_rejection!(rejection([ bad1 ]))
    File.write(File.join(dir, "secret.txt"), "clean\n")
    sh("add", "-A")
    sh("commit", "--amend", "--no-edit")
    recovery.verify_repair!
    pushed = sh("rev-parse", "HEAD")

    expect { recovery.publish! { |_sha| raise rejection([ pushed ]) } }.to raise_error(GithubPushProtection::Rejected)
    expect(ledger.clean_anchor).to eq(anchor)
    expect(ledger.status).to eq("operator_review")
  end

  it "records the new SHA as the clean anchor after a successful push" do
    recovery.handle_rejection!(rejection([ bad1 ]))
    File.write(File.join(dir, "secret.txt"), "clean\n")
    sh("add", "-A")
    sh("commit", "--amend", "--no-edit")
    recovery.verify_repair!
    pushed = sh("rev-parse", "HEAD")

    recovery.publish! { |sha| expect(sha).to eq(pushed) }

    expect(ledger.clean_anchor).to eq(pushed)
    expect(ledger.status).to eq("resolved")
  end

  it "suppresses ordinary checkpoint publication while a repair is active" do
    recovery.handle_rejection!(rejection([ bad1 ]))
    run = workflow.steps.find_by!(kind: "implement").runs.create!(
      job: job, user: user, trigger_kind: workflow.trigger_kind, agent_provider: "claude", state: "succeeded", head_sha: "abc123"
    )
    git = instance_double(GitRunner)
    expect(GithubAuthenticatedGit).not_to receive(:run)

    expect(RunCheckpointPublisher.publish!(run: run, workspace: instance_double(WorkflowWorkspace, path: Pathname.new(dir)), git: git)).to be_nil
  end

  it "flags a planted git hook and restores the baseline hooks on reset" do
    recovery.handle_rejection!(rejection([ bad1 ]))
    hook = File.join(dir, ".git/hooks/pre-push")
    File.write(hook, "#!/bin/sh\necho $2 > /tmp/leak\n")
    File.chmod(0o755, hook)
    File.write(File.join(dir, "secret.txt"), "clean\n")
    sh("-c", "core.hooksPath=/dev/null", "commit", "-a", "--amend", "--no-edit", "--no-verify")

    outcome = recovery.verify_repair!

    expect(outcome.kind).to eq(:contract_violation)
    expect(outcome.violations.join).to include("Git metadata changed").and include("hooks/pre-push")

    recovery.restore_candidate!
    expect(File.exist?(hook)).to be(false)
    expect(sh("rev-parse", "HEAD")).to eq(ledger.data["candidate_sha"])
  end

  it "flags edits to .git/info and core.hooksPath" do
    recovery.handle_rejection!(rejection([ bad1 ]))
    File.write(File.join(dir, ".git/info/attributes"), "* filter=evil\n")
    sh("config", "core.hooksPath", "/tmp/evil")

    violations = recovery.verify_repair!.violations.join("\n")

    expect(violations).to include("Repository configuration").and include("info/attributes")
  end

  it "allows any file the rejected range changed when GitHub reports no locations" do
    error = GithubPushProtection::Rejected.new([ "push", "x", "HEAD:refs/heads/#{branch}" ], 1, findings: [], ref: "refs/heads/#{branch}")
    recovery.handle_rejection!(error)
    File.write(File.join(dir, "secret.txt"), "clean\n")
    sh("add", "-A")
    sh("commit", "--amend", "--no-edit")

    expect(recovery.verify_repair!.kind).to eq(:verified)
  end
end
