require "rails_helper"
require "tmpdir"
require "open3"

RSpec.describe Steps::Summarize, :ci_only do
  let(:user)     { Factories.user(name: "Ada Lovelace", email_address: "ada@example.com") }
  let(:repository) { Factories.repository(user: user) }
  let(:job)      { Factories.job(repository: repository) }   # issue_number: 42
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }
  let(:step)     { Step.create!(workflow: workflow, kind: "summarize", position: 0) }
  let(:run)      do
    Run.create!(job: job, step: step, trigger_kind: "initial").tap { |r| r.start!; r.save! }
  end
  let(:handler) { described_class.new(run) }

  around do |ex|
    Dir.mktmpdir("syrus-summarize") do |dir|
      @ws_path = Pathname.new(dir)
      ex.run
    end
  end

  before do
    # Seed a git repo with a real-file implement commit (not --allow-empty;
    # git refuses to amend an empty commit without --allow-empty, and the
    # production implement step always writes at least one file).
    git_env = {
      "GIT_AUTHOR_NAME"     => "Test",
      "GIT_AUTHOR_EMAIL"    => "test@test.com",
      "GIT_COMMITTER_NAME"  => "Test",
      "GIT_COMMITTER_EMAIL" => "test@test.com"
    }
    sh(git_env, "git -c init.defaultBranch=main init -q #{@ws_path}")
    sh(git_env, "git -C #{@ws_path} config user.name 'Ada Lovelace'")
    sh(git_env, "git -C #{@ws_path} config user.email 'ada@example.com'")
    File.write(@ws_path.join("feature.rb"), "def greet = 'hello'\n")
    sh(git_env, "git -C #{@ws_path} add feature.rb")
    sh(git_env, "git -C #{@ws_path} commit -q -m 'Syrus implement step (will be rewritten by summarize)'")

    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path,
                              branch_name: "syrus/issue-42-#{job.id}")
    allow(handler).to receive(:workspace).and_return(fake_ws)
  end

  # Stub run_agent to write agent_pr_title/body onto the Run
  # (simulates MCP sidecar writing mid-run), then return success.
  def stub_agent(title:, body: nil, summary: nil)
    allow(handler).to receive(:run_agent) do
      run.update!(agent_pr_title: title, agent_pr_body: body, agent_summary: summary)
    end
  end

  def commit_message
    `git -C #{@ws_path} log -1 --format='%B'`.strip
  end

  describe "coding handoff workflows" do
    let(:workflow) do
      Workflow.create!(
        job: job,
        trigger_kind: "coding_handoff",
        artifacts: {
          "pr_title" => "Use captured chat title",
          "pr_body" => "Use captured chat body.",
          "summary" => "Captured from chat handoff."
        }
      )
    end

    it "uses captured artifacts instead of invoking a fresh summarizer agent" do
      original_message = commit_message

      expect(handler).not_to receive(:run_agent)
      handler.call

      expect(commit_message).to eq(original_message)
      expect(workflow.reload.artifact("pr_title")).to eq("Use captured chat title")
    end

    it "fails loudly if the coding handoff did not capture summary artifacts" do
      workflow.update!(artifacts: {})

      expect(handler).not_to receive(:run_agent)
      expect {
        handler.call
      }.to raise_error(Steps::Base::StepFailed, /missing coding handoff summary artifacts/)
    end
  end

  describe "skipping agent when implement step already submitted summary" do
    let(:implement_step) do
      Step.create!(workflow: workflow, kind: "implement", position: 0, next_step_id: step.id)
    end
    let(:implement_run) do
      r = Run.create!(job: job, step: implement_step, trigger_kind: "initial",
                      agent_pr_title: "Add greeting helper",
                      agent_pr_body:  "Adds a tiny helper.",
                      agent_summary:  "Added a greeting helper method.")
      r.start!; r.succeed!; r.save!
      r
    end

    before { implement_run }

    it "does not invoke the agent" do
      expect(handler).not_to receive(:run_agent)
      handler.call
    end

    it "promotes pr_title from the implement run onto workflow artifacts" do
      handler.call
      expect(workflow.reload.artifact("pr_title")).to eq("Add greeting helper")
    end

    it "promotes pr_body and summary from the implement run" do
      handler.call
      workflow.reload
      expect(workflow.artifact("pr_body")).to eq("Adds a tiny helper.")
      expect(workflow.artifact("summary")).to eq("Added a greeting helper method.")
    end

    it "normalizes binary-tagged UTF-8 summary artifacts" do
      implement_run.assign_attributes(
        agent_pr_title: "Add ● helper".b,
        agent_pr_body: "Adds ● body.".b,
        agent_summary: "Stored ● summary.".b
      )
      allow(handler).to receive(:implement_run_with_summary).and_return(implement_run)

      handler.call

      workflow.reload
      expect(workflow.artifact("pr_title")).to eq("Add ● helper")
      expect(workflow.artifact("pr_body")).to eq("Adds ● body.")
      expect(workflow.artifact("summary")).to eq("Stored ● summary.")
      expect(workflow.artifact("pr_title").encoding).to eq(Encoding::UTF_8)
    end

    it "rewrites the commit message using the implement run's pr_title" do
      handler.call
      expect(commit_message).to start_with("Add greeting helper")
    end
  end

  describe "commit message rewrite" do
    it "uses a larger turn budget for the MCP summary handoff" do
      expect(handler).to receive(:run_agent).with(
        prompt: kind_of(String),
        max_turns: described_class::SUMMARIZE_TURN_BUDGET,
        required_mcp_tools: %w[submit_summary]
      ) do
        run.update!(
          agent_pr_title: "Add greeting helper",
          agent_pr_body: "Adds a tiny helper.",
          agent_summary: "Added a greeting helper."
        )
      end

      handler.call
    end

    it "retries summarize without --resume when the resumed prompt is too large" do
      implement_step = Step.create!(workflow: workflow, kind: "implement", position: 0, next_step_id: step.id)
      implement_run = Run.create!(
        job: job,
        step: implement_step,
        trigger_kind: "initial",
        state: "succeeded",
        agent_diff: "diff --git a/feature.rb b/feature.rb\n+def greet = 'hi'\n"
      )
      ProviderSession.create!(resumable: implement_run, session_id: "S-implement", transcript_jsonl: "{}\n")

      calls = []
      allow(handler).to receive(:run_agent) do |prompt:, **kwargs|
        calls << { prompt: prompt, kwargs: kwargs }
        if calls.size == 1
          JobLog.append!(run: run, chunk: "Claude API error: Prompt is too long", kind: "system")
          raise Steps::Base::StepFailed, "agent reported api_error"
        end

        expect(kwargs[:resume_session_id]).to be_nil
        expect(prompt).to include("original agent session was too large to resume")
        expect(prompt).to include("def greet = 'hi'")
        run.update!(
          agent_pr_title: "Add greeting helper",
          agent_pr_body: "Summarized from the bounded implementation diff.",
          agent_summary: "Added a greeting helper."
        )
      end

      handler.call

      expect(calls.size).to eq(2)
      expect(calls.map { |call| call[:kwargs][:max_turns] }).to eq([
        described_class::SUMMARIZE_TURN_BUDGET,
        described_class::SUMMARIZE_TURN_BUDGET
      ])
      expect(workflow.reload.artifact("pr_title")).to eq("Add greeting helper")
      expect(run.job_logs.pluck(:chunk).join("\n")).to include("retrying summary without --resume")
    end

    it "retries summarize without --resume when Codex resume rollout is unavailable" do
      workflow.update!(agent_provider: "codex")
      implement_step = Step.create!(workflow: workflow, kind: "implement", position: 0, next_step_id: step.id)
      implement_run = Run.create!(
        job: job,
        step: implement_step,
        trigger_kind: "initial",
        state: "succeeded",
        agent_diff: "diff --git a/feature.rb b/feature.rb\n+def greet = 'hi'\n"
      )
      ProviderSession.create!(resumable: implement_run, session_id: "019f-missing", provider: "codex")

      calls = []
      allow(handler).to receive(:run_agent) do |prompt:, **kwargs|
        calls << { prompt: prompt, kwargs: kwargs }
        if calls.size == 1
          JobLog.append!(
            run: run,
            chunk: "[codex resume] resume for session 019f-missing did not complete successfully: thread/resume failed: no rollout found for thread id 019f-missing",
            kind: "system"
          )
          raise Steps::Base::StepFailed, "agent exited 1"
        end

        expect(kwargs[:resume_session_id]).to be_nil
        expect(prompt).to include("original agent session was too large to resume")
        run.update!(
          agent_pr_title: "Add greeting helper",
          agent_pr_body: "Summarized from fallback.",
          agent_summary: "Added a greeting helper."
        )
      end

      handler.call

      expect(calls.size).to eq(2)
      expect(workflow.reload.artifact("pr_title")).to eq("Add greeting helper")
      expect(run.job_logs.pluck(:chunk).join("\n")).to include("Codex resume state was unavailable")
    end

    it "amends the placeholder commit subject to the agent-authored pr_title" do
      stub_agent(title: "Add greeting helper", body: "Adds a tiny helper.")
      handler.call
      expect(commit_message).to start_with("Add greeting helper")
    end

    it "fails if the summarize agent changes workspace contents before submitting metadata" do
      allow(handler).to receive(:run_agent) do
        File.write(@ws_path.join("wrong_skill.rb"), "class WrongSkill; end\n")
        sh("git -C #{@ws_path} add wrong_skill.rb")
        sh("git -C #{@ws_path} commit -q -m 'Unrelated content change'")
        run.update!(
          agent_pr_title: "Add greeting helper",
          agent_pr_body: "Adds a tiny helper.",
          agent_summary: "Added a greeting helper."
        )
      end

      expect {
        handler.call
      }.to raise_error(Steps::Base::StepFailed, /metadata-only steps must only call MCP tools/)
      expect(commit_message).to eq("Unrelated content change")
      expect(workflow.reload.artifact("pr_title")).to be_nil
    end

    it "includes pr_body in the commit message body when present" do
      stub_agent(title: "Add greeting helper", body: "Adds a tiny helper.")
      handler.call
      expect(commit_message).to include("Adds a tiny helper.")
    end

    it "defensively prepends 'Closes #N' when pr_body does not include it" do
      stub_agent(title: "Add greeting helper", body: "Adds a tiny helper.")
      handler.call
      expect(commit_message).to include("Closes ##{job.issue_number}")
    end

    it "does not double-prepend 'Closes #N' when pr_body already contains it" do
      stub_agent(title: "Add greeting helper",
                 body: "Closes ##{job.issue_number}\n\nAdds a tiny helper.")
      handler.call
      expect(commit_message.scan(/Closes ##{job.issue_number}/).size).to eq(1)
    end

    it "uses the title plus human co-author trailer when pr_body is blank" do
      stub_agent(title: "Add greeting helper", body: nil)
      handler.call
      expect(commit_message).to eq("Add greeting helper\n\nCo-Authored-By: Ada Lovelace <ada@example.com>")
    end

    it "amends cleanly when the implement HEAD is an empty commit" do
      # Parity with SummarizeAmend: relabeling an empty commit must not fail
      # with git's "amending would make it empty".
      git_env = {
        "GIT_AUTHOR_NAME" => "Test", "GIT_AUTHOR_EMAIL" => "test@test.com",
        "GIT_COMMITTER_NAME" => "Test", "GIT_COMMITTER_EMAIL" => "test@test.com"
      }
      sh(git_env, "git -C #{@ws_path} commit -q --allow-empty -m 'placeholder empty'")

      stub_agent(title: "Add greeting helper", body: nil)

      expect { handler.call }.not_to raise_error
      expect(commit_message).to start_with("Add greeting helper")
      expect(`git -C #{@ws_path} diff --stat HEAD^ HEAD`.strip).to eq("")
    end

    it "does not add 'Closes #N' for cron jobs (no issue_number)" do
      cron_task = ScheduledTask.create!(
        user: job.user, repository: job.repository,
        name: "Sweep dead code", prompt: "Look for dead code.",
        kind: "cron", cron_expression: "0 9 * * 1", pr_pileup_policy: "skip"
      )
      cron_job = Job.create!(
        user: job.user, repository: job.repository,
        kind: "cron", scheduled_task: cron_task
      )
      cron_workflow = Workflow.create!(job: cron_job, trigger_kind: "initial")
      cron_step     = Step.create!(workflow: cron_workflow, kind: "summarize", position: 0)
      cron_run      = Run.create!(job: cron_job, step: cron_step, trigger_kind: "initial")
                         .tap { |r| r.start!; r.save! }

      cron_handler = described_class.new(cron_run)
      allow(cron_handler).to receive(:workspace).and_return(
        instance_double(WorkflowWorkspace, setup: nil, path: @ws_path, branch_name: "syrus/scheduled-1-2")
      )
      allow(cron_handler).to receive(:run_agent) do
        cron_run.update!(agent_pr_title: "Sweep dead code", agent_pr_body: "Removed unused methods.")
      end

      cron_handler.call
      expect(commit_message).not_to include("Closes #")
      expect(commit_message).not_to include("Co-Authored-By:")
    end

    it "raises StepFailed when the agent did not call submit_summary (title blank)" do
      allow(handler).to receive(:run_agent)  # agent bails without calling submit_summary
      expect { handler.call }.to raise_error(Steps::Base::StepFailed, /didn't call submit_summary/)
    end
  end

  def sh(*args)
    env, cmd = args.size == 2 ? args : [ {}, args.fetch(0) ]
    out, err, status = Open3.capture3(env, cmd)
    raise "shell failed: #{cmd}\n#{out}\n#{err}" unless status.success?
    out
  end
end
