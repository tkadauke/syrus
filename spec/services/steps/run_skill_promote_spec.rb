require "rails_helper"
require "tmpdir"
require "open3"

# Integration coverage for the repo-local `.syrus/skills/promote/SKILL.md`
# skill (EPIC-235), reusing the Steps::RunSkill harness JOB-3152 established
# for the built-in `investigate` seed skill (spec/services/steps/run_skill_spec.rb).
#
# The skill itself is prose an LLM agent follows, not Ruby code — there is
# nothing here to unit-test at the git-mechanics level directly. What these
# specs do instead is resolve the *real* checked-in SKILL.md (proving it
# parses/renders end to end through the actual run_skill pipeline) and drive
# a real git repository through the three git outcomes the skill's own
# instructions describe (clean fast-forward, merge-commit, conflict),
# standing in for a compliant agent, then assert Steps::RunSkill's
# deterministic side of the contract holds: a successful promotion produces
# a diff Syrus can hand to summarize/pr_open, and a conflict leaves the
# target branch untouched and produces no diff for Syrus to publish, rather
# than a corrupted or force-pushed history.
RSpec.describe Steps::RunSkill, "with the repo-local promote skill" do
  let(:promote_resolution) do
    path = Rails.root.join(".syrus/skills/promote/SKILL.md")
    Skills::Resolution.new(
      source: :repo_override,
      path: ".syrus/skills/promote/SKILL.md",
      klass: nil,
      definition: Skills::SkillMarkdown.parse(File.read(path), name: "promote")
    )
  end

  let(:job) do
    Factories.job(
      kind: "direct",
      issue_number: nil,
      issue_title: "Skill: promote",
      skill_name: "promote",
      skill_args: skill_args,
      target_branch: "main"
    )
  end
  let(:skill_args) { { "source_branch" => "development", "target_branch" => "main", "strategy" => strategy, "open_pr" => true } }
  let(:strategy) { "merge_commit" }

  let(:workflow) { job.workflows.last }
  let(:step)     { workflow.steps.find_by(kind: "run_skill") }
  let(:run)      { step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind) }
  let(:handler)  { described_class.new(run) }

  around do |ex|
    Dir.mktmpdir("syrus-promote-origin") do |origin_dir|
      Dir.mktmpdir("syrus-promote-ws") do |ws_dir|
        @origin_path = Pathname.new(origin_dir)
        @ws_path = Pathname.new(ws_dir)
        ex.run
      end
    end
  end

  def git!(*args, dir: @ws_path)
    out, err, status = Open3.capture3("git", "-C", dir.to_s, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out
  end

  def git(*args, dir: @ws_path)
    Open3.capture3("git", "-C", dir.to_s, *args)
  end

  def write(relative_path, content)
    @ws_path.join(relative_path).write(content)
  end

  # Base repo: an `origin` bare remote, plus a working clone already on
  # `main` (mirrors the workspace WorkflowWorkspace hands the agent: checked
  # out on a branch based on the current tip of target_branch, per
  # Job#target_branch). A real remote (not just local branches) matters here
  # because `default_branch_ref` diffs against the frozen `origin/main`
  # remote-tracking ref, not the local branch that races ahead as the
  # "agent" merges — exactly the semantics Steps::Base relies on in
  # production.
  def init_base_repo!
    Open3.capture3("git", "init", "--bare", chdir: @origin_path.to_s)

    git!("init", "-b", "main")
    git!("config", "user.email", "promote-test@example.com")
    git!("config", "user.name", "Promote Test")
    git!("remote", "add", "origin", @origin_path.to_s)

    write("README.md", "base\n")
    git!("add", "-A")
    git!("commit", "-m", "base commit")
    git!("push", "origin", "main")
  end

  def push_development_branch!(content: "feature\n")
    git!("checkout", "-b", "development")
    write("feature.txt", content)
    git!("add", "-A")
    git!("commit", "-m", "add feature")
    git!("push", "origin", "development")
    git!("checkout", "main")
  end

  def fetch_default_branch_ref!
    git!("fetch", "origin", "main")
  end

  before do
    allow(Skills).to receive(:for).and_return(promote_resolution)

    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path, base_ref: "origin/main")
    allow(handler).to receive(:workspace).and_return(fake_ws)
  end

  describe "records skill provenance and renders the prompt for the real SKILL.md" do
    before do
      init_base_repo!
      push_development_branch!
      fetch_default_branch_ref!
      allow(handler).to receive(:run_agent) do
        git!("fetch", "origin", "development")
        git!("merge", "--no-ff", "origin/development", "-m", "promote")
      end
    end

    it "resolves the repo-local definition and renders strategy/open_pr into the prompt" do
      handler.call

      run.reload
      expect(run.skill_source).to eq("repo_override")
      expect(run.skill_resolved_path).to eq(".syrus/skills/promote/SKILL.md")
      expect(run.prompt).to include("source_branch=`development`")
      expect(run.prompt).to include("target_branch=`main`")
      expect(run.prompt).to include("strategy=`merge_commit`")
      expect(run.prompt).to include("open_pr=`true`")
    end
  end

  context "clean fast-forward (strategy=fast_forward, main hasn't diverged)" do
    let(:strategy) { "fast_forward" }

    before do
      init_base_repo!
      push_development_branch!
      fetch_default_branch_ref!

      # Simulates a compliant agent following the SKILL.md's step 1-2 for
      # strategy=fast_forward: fetch, then `git merge --ff-only`.
      allow(handler).to receive(:run_agent) do
        git!("fetch", "origin", "development")
        git!("merge", "--ff-only", "origin/development")
      end
    end

    it "fast-forwards cleanly and produces a diff for Syrus to publish" do
      handler.call

      run.reload
      expect(run.agent_diff).to include("feature.txt")
      # A true fast-forward advances the branch pointer without a merge commit.
      expect(git!("rev-list", "--merges", "origin/main..HEAD").strip).to be_empty
      expect(git!("log", "-1", "--format=%s").strip).to eq("add feature")
    end
  end

  context "merge_commit (main has an independent commit since development branched)" do
    let(:strategy) { "merge_commit" }

    before do
      init_base_repo!
      push_development_branch!

      # main diverges independently (e.g. a prior promotion, or a hotfix
      # landed straight on main) — this is exactly the case the SKILL.md
      # tells the agent to still land as a merge commit rather than
      # attempting (and failing) a fast-forward.
      write("main-note.txt", "unrelated main-side change\n")
      git!("add", "-A")
      git!("commit", "-m", "unrelated main-side change")
      git!("push", "origin", "main")
      fetch_default_branch_ref!

      allow(handler).to receive(:run_agent) do
        git!("fetch", "origin", "development")
        git!("merge", "--no-ff", "origin/development", "-m", "promote development into main")
      end
    end

    it "creates a merge commit joining both parents and produces a diff for the new content only" do
      handler.call

      run.reload
      expect(run.agent_diff).to include("feature.txt")
      expect(run.agent_diff).not_to include("main-note.txt") # already on main before this run
      merge_parents = git!("log", "-1", "--format=%P").strip.split
      expect(merge_parents.size).to eq(2)
    end
  end

  context "conflict (main and development touch the same line differently)" do
    let(:strategy) { "merge_commit" }

    before do
      init_base_repo!

      git!("checkout", "-b", "development")
      write("README.md", "from development\n")
      git!("add", "-A")
      git!("commit", "-m", "development changes the shared line")
      git!("push", "origin", "development")

      git!("checkout", "main")
      write("README.md", "from main\n")
      git!("add", "-A")
      git!("commit", "-m", "main changes the same shared line")
      git!("push", "origin", "main")
      fetch_default_branch_ref!

      # Simulates the SKILL.md's step 4: on conflict, abort and leave the
      # target branch exactly as it was — no force-push, no broken commit.
      allow(handler).to receive(:run_agent) do
        git!("fetch", "origin", "development")
        _, _, merge_status = git("merge", "--no-ff", "origin/development", "-m", "promote development into main")
        raise "expected a conflict in this scenario" if merge_status.success?

        git!("merge", "--abort")
      end
    end

    it "leaves the target branch untouched and raises NoChangesProduced instead of publishing anything" do
      pre_run_sha = git!("rev-parse", "HEAD").strip

      expect { handler.call }.to raise_error(Steps::Base::NoChangesProduced)

      expect(git!("status", "--porcelain").strip).to be_empty
      expect(git!("rev-parse", "HEAD").strip).to eq(pre_run_sha)
      run.reload
      expect(run.skill_source).to eq("repo_override") # provenance still recorded before the raise
      expect(run.agent_diff).to be_nil
    end
  end
end
