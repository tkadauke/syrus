require "rails_helper"
require "tmpdir"

# End-to-end recovery through a real step (Steps::Push) against a real git
# workspace. Only the network boundary (the push itself) and the agent are faked.
RSpec.describe Steps::PushProtectionRecovery do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "running") }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "pr_comment", agent_provider: "claude") }
  let(:step) { Step.create!(workflow: workflow, kind: "push", position: 0) }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "pr_comment", agent_provider: "claude") }
  let(:dir) { Dir.mktmpdir("pp-step") }
  let(:data_root) { Dir.mktmpdir("pp-data") }
  let(:branch) { job.branch_name.presence || "syrus/job-test" }
  let(:ledger) { PushProtection::Ledger.for(workflow) }
  let(:handler) { Steps::Push.new(run) }
  let(:pushes) { [] }

  # Fakes only `git push`; everything else is real git.
  let(:fake_git) do
    pushes_log = pushes
    rejecting = push_results
    Class.new do
      define_method(:run) do |*args, **kw|
        if args.first == "push"
          pushes_log << `git -C #{kw[:chdir]} rev-parse HEAD`.strip
          result = rejecting.shift
          raise result if result.is_a?(Exception)

          return ""
        end
        GitRunner.new.run(*args, **kw)
      end
    end.new
  end
  let(:push_results) { [] }

  def sh(*args, env: {})
    out, status = Open3.capture2e(ENV.to_h.merge(env), "git", *args, chdir: dir)
    raise "git #{args.join(' ')}: #{out}" unless status.success?

    out.strip
  end

  def commit_file(path, content, msg)
    File.write(File.join(dir, path), content)
    sh("add", "-A")
    sh("commit", "-m", msg)
    sh("rev-parse", "HEAD")
  end

  def rejection(sha, ref: "refs/heads/#{branch}")
    finding = GithubPushProtection::Finding.new(secret_type: "Token", commit_sha: sha, path: "secret.txt", line: 1)
    GithubPushProtection::Rejected.new([ "push", "x", "HEAD:#{ref}" ], 1, findings: [ finding ], ref: ref)
  end

  before do
    allow(WorkflowWorkspace).to receive(:data_root).and_return(Pathname.new(data_root))
    sh("init", "-q", "-b", "main")
    sh("config", "user.email", "t@example.com")
    sh("config", "user.name", "T")
    @anchor = commit_file("README.md", "hi\n", "base")
    sh("checkout", "-q", "-b", branch)
    @bad1 = commit_file("secret.txt", "TOKEN=abc\n", "add config")
    @bad2 = commit_file("other.txt", "ok\n", "more")
    ledger.seed_anchor!(@anchor)

    allow(handler).to receive(:workspace).and_return(instance_double(WorkflowWorkspace, setup: nil, branch_name: branch, path: Pathname.new(dir)))
    allow(handler).to receive(:streaming_git).and_return(fake_git)
    allow(handler).to receive(:authenticated_git) { |_op, **_kw, &block| block.call("https://example.test/repo.git") }
    allow(handler).to receive(:push_protection_remote_tip).and_return(nil)
    allow(JobMetadataRefreshApplier).to receive(:new).and_return(instance_double(JobMetadataRefreshApplier, call: nil))
  end

  after { FileUtils.rm_rf([ dir, data_root ]) }

  def fix_secret(content = "TOKEN=<redacted>\n")
    File.write(File.join(dir, "secret.txt"), content)
    sh("add", "-A")
    sh("commit", "--amend", "--no-edit")
  end

  it "repairs the rejected range, republishes one clean commit, and advances the anchor only after acceptance" do
    push_results.replace([ rejection(@bad1), nil ])
    prompts = []
    allow(handler).to receive(:run_agent) { |prompt:, **| prompts << prompt; fix_secret }

    handler.call

    expect(pushes.size).to eq(2)
    expect(pushes.first).to eq(@bad2)
    expect(pushes.last).not_to eq(@bad2)
    expect(sh("rev-list", "--parents", "-n", "1", "HEAD").split.drop(1)).to eq([ @anchor ])
    expect(ledger.clean_anchor).to eq(pushes.last)
    expect(ledger.status).to eq("resolved")
    expect(prompts.size).to eq(1)
    expect(prompts.first).to include("Token in secret.txt:1").and include(@anchor)
    expect(prompts.first).not_to include("abc")
  end

  it "retries once with precise feedback after a contract violation, then publishes" do
    push_results.replace([ rejection(@bad1), nil ])
    prompts = []
    calls = 0
    allow(handler).to receive(:run_agent) do |prompt:, **|
      prompts << prompt
      calls += 1
      if calls == 1
        sh("branch", "stray")
        sh("commit", "--allow-empty", "-m", "second commit")
      else
        expect(sh("rev-parse", "HEAD")).to eq(ledger.data["candidate_sha"]) # reset to candidate
        expect(sh("branch", "--list", "stray")).to eq("")
        fix_secret
      end
    end

    handler.call

    expect(prompts.last).to include("violated the repair contract").and include("exactly one parent")
    expect(ledger.status).to eq("resolved")
  end

  it "stops for operator review after the bounded limit and never pushes" do
    push_results.replace([ rejection(@bad1) ])
    allow(handler).to receive(:run_agent) { |**| sh("commit", "--allow-empty", "-m", "extra") }

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /push protection/i)

    expect(pushes.size).to eq(1)
    expect(ledger.status).to eq("operator_review")
    expect(ledger.evidence["findings"]).to be_present
  end

  it "requires operator review when GitHub rejects the reconstructed commit too" do
    push_results.replace([ rejection(@bad1), rejection(@bad1) ])
    allow(handler).to receive(:run_agent) { |**| fix_secret("TOKEN=still-bad\n") }

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /still rejected/)

    expect(pushes.size).to eq(2)
    expect(ledger.status).to eq("operator_review")
    expect(ledger.clean_anchor).to eq(@anchor)
  end

  it "stops on upstream contamination without dispatching an agent" do
    push_results.replace([ rejection(@anchor) ])
    expect(handler).not_to receive(:run_agent)

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /upstream/)

    expect(sh("rev-parse", "HEAD")).to eq(@bad2)
    expect(ledger.status).to eq("upstream_contaminated")
  end

  it "quarantines a rejected merge-train ref and routes it to the member Jobs" do
    other_job = Factories.job_record(user: user, repository: repository, state: "running")
    other_wf = Workflow.create!(job: other_job, trigger_kind: "pr_comment", agent_provider: "claude")
    train = instance_double(MergeTrain, jobs: Job.where(id: other_job.id))
    allow(MergeTrain).to receive(:find_by).and_return(train)
    push_results.replace([ rejection(@bad1, ref: "refs/heads/syrus/merge-train/9") ])
    expect(handler).not_to receive(:run_agent)

    expect { handler.call }.to raise_error(Steps::Base::StepFailed)

    expect(sh("rev-parse", "HEAD")).to eq(@bad2)
    expect(ledger.status).to eq("quarantined")
    expect(PushProtection::Ledger.for(other_wf.reload).data).to include("status" => "quarantined", "routed_from_workflow_id" => workflow.id)
  end

  it "never leaks bypass URLs or secrets into the failure message" do
    push_results.replace([ rejection(@anchor) ])

    expect { handler.call }.to raise_error(Steps::Base::StepFailed) { |e|
      expect(e.message).not_to include("unblock-secret")
    }
  end
end
