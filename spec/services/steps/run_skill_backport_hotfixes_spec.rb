require "rails_helper"
require "tmpdir"
require "open3"

# Integration coverage for the repo-local
# `.syrus/skills/backport-hotfixes/SKILL.md` skill (EPIC-235), reusing the
# Steps::RunSkill harness JOB-3152 established for the `promote` skill
# (spec/services/steps/run_skill_promote_spec.rb) and the built-in
# `investigate` seed skill before it.
#
# The skill itself is prose an LLM agent follows, not Ruby code — there is
# nothing here to unit-test at the git-mechanics level directly. What these
# specs do instead is resolve the *real* checked-in SKILL.md (proving it
# parses/renders end to end through the actual run_skill pipeline) and drive
# a real git repository through the git outcomes the skill's own
# instructions describe (already in sync, clean cherry-pick, conflict,
# max_commits bounding), standing in for a compliant agent, then assert
# Steps::RunSkill's deterministic side of the contract holds.
RSpec.describe Steps::RunSkill, "with the repo-local backport-hotfixes skill" do
  let(:backport_resolution) do
    path = Rails.root.join(".syrus/skills/backport-hotfixes/SKILL.md")
    Skills::Resolution.new(
      source: :repo_override,
      path: ".syrus/skills/backport-hotfixes/SKILL.md",
      klass: nil,
      definition: Skills::SkillMarkdown.parse(File.read(path), name: "backport-hotfixes")
    )
  end

  let(:job) do
    Factories.job(
      kind: "direct",
      issue_number: nil,
      issue_title: "Skill: backport-hotfixes",
      skill_name: "backport-hotfixes",
      skill_args: skill_args,
      target_branch: "development"
    )
  end
  let(:skill_args) { { "source_branch" => "main", "target_branch" => "development", "max_commits" => max_commits } }
  let(:max_commits) { "" }

  let(:workflow) { job.workflows.last }
  let(:step)     { workflow.steps.find_by(kind: "run_skill") }
  let(:run)      { step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind) }
  let(:handler)  { described_class.new(run) }

  around do |ex|
    Dir.mktmpdir("syrus-backport-origin") do |origin_dir|
      Dir.mktmpdir("syrus-backport-ws") do |ws_dir|
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
  # `development` (mirrors the workspace WorkflowWorkspace hands the agent:
  # checked out on a branch based on the current tip of target_branch, per
  # Job#target_branch). A real remote (not just local branches) matters here
  # because `default_branch_ref` diffs against the frozen `origin/development`
  # remote-tracking ref, not the local branch that races ahead as the
  # "agent" cherry-picks — exactly the semantics Steps::Base relies on in
  # production.
  def init_base_repo!
    Open3.capture3("git", "init", "--bare", chdir: @origin_path.to_s)

    git!("init", "-b", "development")
    git!("config", "user.email", "backport-test@example.com")
    git!("config", "user.name", "Backport Test")
    git!("remote", "add", "origin", @origin_path.to_s)

    write("README.md", "base\n")
    git!("add", "-A")
    git!("commit", "-m", "base commit")
    git!("push", "origin", "development")
  end

  def push_main_branch!(hotfix_count:)
    git!("checkout", "-b", "main")
    hotfix_count.times do |i|
      write("hotfix-#{i}.txt", "hotfix #{i}\n")
      git!("add", "-A")
      git!("commit", "-m", "hotfix #{i}")
    end
    git!("push", "origin", "main")
    git!("checkout", "development")
  end

  def fetch_default_branch_ref!
    git!("fetch", "origin", "development")
  end

  before do
    allow(Skills).to receive(:for).and_return(backport_resolution)

    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path, base_ref: "origin/development")
    allow(handler).to receive(:workspace).and_return(fake_ws)
  end

  describe "records skill provenance and renders the prompt for the real SKILL.md" do
    let(:max_commits) { "2" }

    before do
      init_base_repo!
      push_main_branch!(hotfix_count: 1)
      fetch_default_branch_ref!
      allow(handler).to receive(:run_agent) do
        git!("fetch", "origin", "main")
        git!("cherry-pick", cherry_pickable_shas.first)
      end
    end

    def cherry_pickable_shas
      git!("log", "--reverse", "--format=%H", "origin/development..origin/main").split("\n")
    end

    it "resolves the repo-local definition and renders source/target/max_commits into the prompt" do
      handler.call

      run.reload
      expect(run.skill_source).to eq("repo_override")
      expect(run.skill_resolved_path).to eq(".syrus/skills/backport-hotfixes/SKILL.md")
      expect(run.prompt).to include("source_branch=`main`")
      expect(run.prompt).to include("target_branch=`development`")
      expect(run.prompt).to include("max_commits=`2`")
    end
  end

  context "already in sync (main has no commits development lacks)" do
    before do
      init_base_repo!
      push_main_branch!(hotfix_count: 0) # main == development, e.g. right after a promote run
      fetch_default_branch_ref!

      # Simulates the SKILL.md's step 3: `git log --reverse` returns nothing,
      # so a compliant agent commits nothing at all.
      allow(handler).to receive(:run_agent) do
        git!("fetch", "origin", "main")
        shas = git!("log", "--reverse", "--format=%H", "origin/development..origin/main").split("\n")
        raise "expected no commits to backport in this scenario" unless shas.empty?
      end
    end

    it "raises NoChangesProduced instead of publishing a no-op change" do
      pre_run_sha = git!("rev-parse", "HEAD").strip

      expect { handler.call }.to raise_error(Steps::Base::NoChangesProduced)

      expect(git!("rev-parse", "HEAD").strip).to eq(pre_run_sha)
      run.reload
      expect(run.skill_source).to eq("repo_override")
      expect(run.agent_diff).to be_nil
    end
  end

  context "clean cherry-pick (main has hotfix commits development lacks)" do
    before do
      init_base_repo!
      push_main_branch!(hotfix_count: 2)
      fetch_default_branch_ref!

      # Simulates a compliant agent following the SKILL.md's steps 1-2-5:
      # fetch source, compute the range, cherry-pick each SHA in order.
      allow(handler).to receive(:run_agent) do
        git!("fetch", "origin", "main")
        shas = git!("log", "--reverse", "--format=%H", "origin/development..origin/main").split("\n")
        shas.each { |sha| git!("cherry-pick", sha) }
      end
    end

    it "cherry-picks every commit in order and produces a diff for Syrus to publish" do
      handler.call

      run.reload
      expect(run.agent_diff).to include("hotfix-0.txt")
      expect(run.agent_diff).to include("hotfix-1.txt")
      expect(git!("log", "--format=%s", "origin/development..HEAD").split("\n")).to eq([ "hotfix 1", "hotfix 0" ])
    end
  end

  context "max_commits bounds a run when the backlog is larger than the cap" do
    let(:max_commits) { "1" }

    before do
      init_base_repo!
      push_main_branch!(hotfix_count: 3)
      fetch_default_branch_ref!

      # Simulates the SKILL.md's step 4: only the first (oldest) N commits
      # are cherry-picked even though more remain on main.
      allow(handler).to receive(:run_agent) do
        git!("fetch", "origin", "main")
        shas = git!("log", "--reverse", "--format=%H", "origin/development..origin/main").split("\n").first(1)
        shas.each { |sha| git!("cherry-pick", sha) }
      end
    end

    it "backports only the capped number of commits" do
      handler.call

      run.reload
      expect(run.agent_diff).to include("hotfix-0.txt")
      expect(run.agent_diff).not_to include("hotfix-1.txt")
      expect(run.agent_diff).not_to include("hotfix-2.txt")
      expect(git!("log", "--format=%s", "origin/development..HEAD").split("\n")).to eq([ "hotfix 0" ])
    end
  end

  context "conflict (main and development touch the same line differently)" do
    before do
      init_base_repo!

      git!("checkout", "-b", "main")
      write("README.md", "from main\n")
      git!("add", "-A")
      git!("commit", "-m", "hotfix touching the shared line")
      git!("push", "origin", "main")

      git!("checkout", "development")
      write("README.md", "from development\n")
      git!("add", "-A")
      git!("commit", "-m", "development changes the same shared line")
      git!("push", "origin", "development")
      fetch_default_branch_ref!

      # Simulates the SKILL.md's step 6: on conflict, abort the cherry-pick
      # and leave the branch exactly as it was before that commit.
      allow(handler).to receive(:run_agent) do
        git!("fetch", "origin", "main")
        sha = git!("log", "--reverse", "--format=%H", "origin/development..origin/main").split("\n").first
        _, _, pick_status = git("cherry-pick", sha)
        raise "expected a conflict in this scenario" if pick_status.success?

        git!("cherry-pick", "--abort")
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
