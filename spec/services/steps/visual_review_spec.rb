require "rails_helper"

RSpec.describe Steps::VisualReview do
  let(:job) { Factories.job(issue_title: "Add a dashboard banner", issue_body: "Show a banner on the dashboard.") }
  let(:workflow) { job.workflows.last }
  let(:implement_step) { workflow.steps.find_by!(kind: "implement") }
  let(:implement_run) do
    Run.create!(job: job, step: implement_step, trigger_kind: "initial", state: "succeeded")
  end
  let(:loop_id) { "visual-review-loop-1" }
  let(:review_step) do
    Step.create!(
      workflow: workflow,
      kind: "visual_review",
      position: 100,
      iteration: 1,
      loop_id: loop_id
    )
  end
  let(:run) { Run.create!(job: job, step: review_step, trigger_kind: "initial") }
  let(:handler) { described_class.new(run) }

  before do
    fake_ws = instance_double(WorkflowWorkspace, setup: true, path: Pathname.new("/tmp/workspace"))
    allow(handler).to receive(:workspace).and_return(fake_ws)
    allow(SyrusYml).to receive(:load_repo).with(Pathname.new("/tmp/workspace")).and_raise(Errno::ENOENT)
    allow(App::VisualReviewProjects).to receive(:call).and_return(
      App::VisualReviewProjects::Result.new(
        choices: [
          App::VisualReviewProjects::Choice.new(
            id: "repo",
            label: "Repository",
            path: "",
            owner_config_path: ".syrus.yml",
            seed_notes: nil,
            when_files_changed: nil
          )
        ],
        unavailable_reason: nil
      )
    )

    implement_step.update!(state: "succeeded")
    implement_run.update!(
      agent_diff: "diff --git a/app/views/dashboard/show.html.erb b/app/views/dashboard/show.html.erb\n+<div class=\"banner\">New</div>\n",
      step_agent_diff: "diff --git a/app/views/dashboard/show.html.erb b/app/views/dashboard/show.html.erb\n+<div class=\"banner\">New</div>\n"
    )
  end

  describe "#parent_session_id" do
    before { handler.singleton_class.send(:public, :parent_session_id) }

    it "returns nil on iteration 1" do
      expect(handler.parent_session_id).to be_nil
    end

    it "returns the prior reviewer session on iteration 2 and never the implementer's session" do
      ProviderSession.create!(resumable: implement_run, session_id: "implementer-session", transcript_jsonl: "{}\n")

      prior_run = run
      prior_run.update!(state: "succeeded")
      review_step.update!(state: "succeeded")
      ProviderSession.create!(resumable: prior_run, session_id: "reviewer-session", transcript_jsonl: "{}\n")

      iteration_two_step = Step.create!(
        workflow: workflow,
        kind: "visual_review",
        position: 101,
        iteration: 2,
        loop_id: loop_id
      )
      iteration_two_run = Run.create!(job: job, step: iteration_two_step, trigger_kind: "initial")
      iteration_two_handler = described_class.new(iteration_two_run)
      iteration_two_handler.singleton_class.send(:public, :parent_session_id)

      expect(iteration_two_handler.parent_session_id).to eq("reviewer-session")
      expect(iteration_two_handler.parent_session_id).not_to eq("implementer-session")
    end
  end

  it "calls run_agent without using the change-step commit path" do
    expect(handler).not_to receive(:perform_agentic_change_step)
    expect(handler).to receive(:run_agent) do |prompt: nil, required_mcp_tools: nil, disallowed_tools: nil, **|
      expect(prompt).to include("submit_visual_review")
      expect(prompt).to include("diff --git a/app/views/dashboard/show.html.erb")
      expect(required_mcp_tools).to eq(%w[submit_visual_review])
      expect(disallowed_tools).to eq(%w[ReportFindings])
      workflow.set_artifact!("visual_review_iterations", [
        { "iteration" => review_step.iteration, "critique" => "Looks correct.", "verdict" => "approved" }
      ])
    end

    handler.call

    expect(run.reload.prompt).to include("Show a banner on the dashboard.")
  end

  it "raises StepFailed when the reviewer does not submit findings" do
    allow(handler).to receive(:run_agent)

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /submit_visual_review/)
  end

  it "raises StepFailed when there is no succeeded implement diff" do
    implement_run.update!(agent_diff: nil, step_agent_diff: nil)

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /no succeeded implement diff/)
  end

  it "reviews the latest implement step diff instead of the cumulative stack diff" do
    implement_run.update!(
      agent_diff: <<~DIFF,
        diff --git a/plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx b/plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx
        +<div>parent stack UI change</div>
        diff --git a/app/services/step_dispatcher.rb b/app/services/step_dispatcher.rb
        +dispatch_ready_siblings
      DIFF
      step_agent_diff: <<~DIFF
        diff --git a/app/services/step_dispatcher.rb b/app/services/step_dispatcher.rb
        +dispatch_ready_siblings
      DIFF
    )

    expect(handler).to receive(:run_agent) do |prompt: nil, **|
      expect(prompt).to include("diff --git a/app/services/step_dispatcher.rb")
      expect(prompt).not_to include("DesignDocsSurface")
      workflow.set_artifact!("visual_review_iterations", [
        { "iteration" => review_step.iteration, "critique" => "Not visually testable.", "verdict" => "skipped" }
      ])
    end

    handler.call
  end

  context "in a standalone manual_visual_review workflow (no implement/respond step)" do
    let(:manual_job) { Factories.job_record(issue_title: "Add a dashboard banner", issue_body: "Show a banner on the dashboard.") }
    let(:manual_workflow) do
      Workflow.create!(job: manual_job, trigger_kind: "manual_visual_review", agent_provider: "claude", chain_template: [])
    end
    let(:manual_step) { Step.create!(workflow: manual_workflow, kind: "visual_review", position: 0, iteration: 1) }
    let(:manual_run) { Run.create!(job: manual_job, step: manual_step, trigger_kind: "manual_visual_review") }
    let(:manual_handler) { described_class.new(manual_run) }

    before do
      fake_ws = instance_double(WorkflowWorkspace, setup: true, path: Pathname.new("/tmp/workspace"), base_ref: "origin/main")
      allow(manual_handler).to receive(:workspace).and_return(fake_ws)
      allow(SyrusYml).to receive(:load_repo).with(Pathname.new("/tmp/workspace")).and_raise(Errno::ENOENT)
      allow(App::VisualReviewProjects).to receive(:call).and_return(
        App::VisualReviewProjects::Result.new(
          choices: [
            App::VisualReviewProjects::Choice.new(
              id: "repo",
              label: "Repository",
              path: "",
              owner_config_path: ".syrus.yml",
              seed_notes: nil,
              when_files_changed: nil
            )
          ],
          unavailable_reason: nil
        )
      )
    end

    it "falls back to a fresh git diff against the default branch" do
      allow(manual_handler).to receive(:diff_against_default).and_return(
        "diff --git a/app/views/dashboard/show.html.erb b/app/views/dashboard/show.html.erb\n+<div class=\"banner\">New</div>\n"
      )

      expect(manual_handler).to receive(:run_agent) do |prompt: nil, **|
        expect(prompt).to include("diff --git a/app/views/dashboard/show.html.erb")
        manual_workflow.set_artifact!("visual_review_iterations", [
          { "iteration" => manual_step.iteration, "critique" => "Looks correct.", "verdict" => "approved" }
        ])
      end

      manual_handler.call
    end

    it "raises StepFailed when the branch has no changes to review" do
      allow(manual_handler).to receive(:diff_against_default).and_return("")

      expect { manual_handler.call }.to raise_error(Steps::Base::StepFailed, /no changes to review/)
    end
  end

  context "when the implementer's test plan recommends visual review" do
    before do
      workflow.set_artifact!("test_plan", {
        "steps" => [ "Open /dashboard" ],
        "notes" => nil,
        "visual_review_recommended" => true,
        "visual_review_reason" => "Added a new banner to the dashboard header."
      })
    end

    it "passes the recommendation into the prompt as a hint" do
      expect(handler).to receive(:run_agent) do |prompt: nil, **|
        expect(prompt).to include("recommended running visual review")
        expect(prompt).to include("Added a new banner to the dashboard header.")
        expect(prompt).to include("Treat this as a hint, not a directive")
        workflow.set_artifact!("visual_review_iterations", [
          { "iteration" => review_step.iteration, "critique" => "OK.", "verdict" => "approved" }
        ])
      end

      handler.call
    end
  end

  context "when workspace .syrus.yml has visual_review.seed_notes" do
    before do
      allow(SyrusYml).to receive(:load_repo).with(Pathname.new("/tmp/workspace")).and_return(
        SyrusYml::Config.new(
          prepare: nil, grade: nil, hooks: nil, adversarial_review: nil, agent_insight: nil,
          coverage: nil, formatters: [], generated: [], deployment_stages: [], preview: nil, review_plan: false, deploy: nil,
          delivery: nil, raw_delivery: nil, approval: nil, external_prs: nil, project: nil, targets: [],
          visual_review: SyrusYml::VisualReviewConfig.new(
            enabled: true, rounds: 1, when_files_changed: nil,
            seed_notes: "Log in as demo@example.com / password."
          )
        )
      )
    end

    it "passes seed_notes into the prompt" do
      expect(handler).to receive(:run_agent) do |prompt: nil, **|
        expect(prompt).to include("Log in as demo@example.com / password.")
        workflow.set_artifact!("visual_review_iterations", [
          { "iteration" => review_step.iteration, "critique" => "OK.", "verdict" => "approved" }
        ])
      end

      handler.call
    end
  end

  context "when one affected project preview is available" do
    before do
      implement_run.update!(
        agent_diff: "diff --git a/apps/web/src/App.tsx b/apps/web/src/App.tsx\n+<main>Dashboard</main>\n",
        step_agent_diff: "diff --git a/apps/web/src/App.tsx b/apps/web/src/App.tsx\n+<main>Dashboard</main>\n"
      )
      allow(App::VisualReviewProjects).to receive(:call).and_return(
        App::VisualReviewProjects::Result.new(
          choices: [
            App::VisualReviewProjects::Choice.new(
              id: "web",
              label: "Web",
              path: "apps/web",
              owner_config_path: "apps/web/.syrus.yml",
              seed_notes: "Open /dashboard as demo@example.com.",
              when_files_changed: [ "apps/web/**/*" ]
            )
          ],
          unavailable_reason: nil
        )
      )
    end

    it "passes preview project choices into the prompt and records them on the workflow" do
      expect(handler).to receive(:run_agent) do |prompt: nil, **|
        expect(prompt).to include("Affected preview projects available to this visual review")
        expect(prompt).to include("project_id: web")
        expect(prompt).to include("Call `start_preview` without project_id")
        expect(prompt).to include("Open /dashboard as demo@example.com.")
        workflow.set_artifact!("visual_review_iterations", [
          { "iteration" => review_step.iteration, "critique" => "OK.", "verdict" => "approved" }
        ])
      end

      handler.call

      expect(workflow.reload.artifact("visual_review_preview_projects")).to eq([
        {
          "id" => "web",
          "label" => "Web",
          "path" => "apps/web",
          "owner_config_path" => "apps/web/.syrus.yml",
          "seed_notes" => "Open /dashboard as demo@example.com.",
          "when_files_changed" => [ "apps/web/**/*" ]
        }
      ])
    end
  end

  context "when multiple affected project previews are available" do
    before do
      allow(App::VisualReviewProjects).to receive(:call).and_return(
        App::VisualReviewProjects::Result.new(
          choices: [
            App::VisualReviewProjects::Choice.new(id: "web", label: "Web", path: "apps/web", owner_config_path: "apps/web/.syrus.yml", seed_notes: nil, when_files_changed: nil),
            App::VisualReviewProjects::Choice.new(id: "admin", label: "Admin", path: "apps/admin", owner_config_path: "apps/admin/.syrus.yml", seed_notes: nil, when_files_changed: nil)
          ],
          unavailable_reason: nil
        )
      )
    end

    it "tells the reviewer to select a project_id explicitly" do
      expect(handler).to receive(:run_agent) do |prompt: nil, **|
        expect(prompt).to include("project_id: web")
        expect(prompt).to include("project_id: admin")
        expect(prompt).to include("A bare `start_preview` is ambiguous")
        workflow.set_artifact!("visual_review_iterations", [
          { "iteration" => review_step.iteration, "critique" => "OK.", "verdict" => "approved" }
        ])
      end

      handler.call
    end
  end

  context "when no affected project has a preview" do
    before do
      allow(App::VisualReviewProjects).to receive(:call).and_return(
        App::VisualReviewProjects::Result.new(choices: [], unavailable_reason: "no_affected_preview_project")
      )
    end

    it "skips clearly without invoking the agent" do
      expect(handler).not_to receive(:run_agent)

      handler.call

      expect(workflow.reload.artifact("visual_review_preview_projects_unavailable_reason")).to eq("no_affected_preview_project")
      expect(workflow.artifact("visual_review_iterations").last).to include(
        "verdict" => "skipped",
        "critique" => "No affected project has a preview configured."
      )
    end
  end

  context "when when_files_changed is configured and no changed file matches" do
    before do
      allow(handler.send(:workspace)).to receive(:base_ref).and_return("origin/main")
      allow(SyrusYml).to receive(:load_repo).with(Pathname.new("/tmp/workspace")).and_return(
        SyrusYml::Config.new(
          prepare: nil, grade: nil, hooks: nil, adversarial_review: nil, agent_insight: nil,
          coverage: nil, formatters: [], generated: [], deployment_stages: [], preview: nil, review_plan: false, deploy: nil,
          delivery: nil, raw_delivery: nil, approval: nil, external_prs: nil, project: nil, targets: [],
          visual_review: SyrusYml::VisualReviewConfig.new(
            enabled: true, rounds: 1, when_files_changed: [ "app/frontend/**/*" ],
            seed_notes: nil
          )
        )
      )
      allow(GitRunner).to receive(:new).and_return(instance_double(GitRunner).tap do |git|
        allow(git).to receive(:run).with("diff", "--name-only", anything, chdir: "/tmp/workspace")
                                    .and_return("app/views/dashboard/show.html.erb\n")
      end)
    end

    it "skips the agent turn and records a skipped verdict" do
      expect(handler).not_to receive(:run_agent)

      handler.call

      expect(workflow.reload.artifact("visual_review_iterations")).to eq([
        {
          "iteration" => review_step.iteration,
          "critique" => "No changed files matched the configured visual_review.when_files_changed patterns.",
          "verdict" => "skipped"
        }
      ])
    end
  end

  context "when when_files_changed is configured and a changed file matches" do
    before do
      allow(handler.send(:workspace)).to receive(:base_ref).and_return("origin/main")
      allow(SyrusYml).to receive(:load_repo).with(Pathname.new("/tmp/workspace")).and_return(
        SyrusYml::Config.new(
          prepare: nil, grade: nil, hooks: nil, adversarial_review: nil, agent_insight: nil,
          coverage: nil, formatters: [], generated: [], deployment_stages: [], preview: nil, review_plan: false, deploy: nil,
          delivery: nil, raw_delivery: nil, approval: nil, external_prs: nil, project: nil, targets: [],
          visual_review: SyrusYml::VisualReviewConfig.new(
            enabled: true, rounds: 1, when_files_changed: [ "app/views/**/*" ],
            seed_notes: nil
          )
        )
      )
      allow(GitRunner).to receive(:new).and_return(instance_double(GitRunner).tap do |git|
        allow(git).to receive(:run).with("diff", "--name-only", anything, chdir: "/tmp/workspace")
                                    .and_return("app/views/dashboard/show.html.erb\n")
      end)
    end

    it "invokes the agent as normal" do
      expect(handler).to receive(:run_agent) do |prompt: nil, **|
        workflow.set_artifact!("visual_review_iterations", [
          { "iteration" => review_step.iteration, "critique" => "OK.", "verdict" => "approved" }
        ])
      end

      handler.call
    end
  end

  context "when when_files_changed is configured for UI files but only a parent stack commit touched UI" do
    before do
      allow(SyrusYml).to receive(:load_repo).with(Pathname.new("/tmp/workspace")).and_return(
        SyrusYml::Config.new(
          prepare: nil, grade: nil, hooks: nil, adversarial_review: nil, agent_insight: nil,
          coverage: nil, formatters: [], generated: [], deployment_stages: [], preview: nil, review_plan: false, deploy: nil,
          delivery: nil, raw_delivery: nil, approval: nil, external_prs: nil, project: nil, targets: [],
          visual_review: SyrusYml::VisualReviewConfig.new(
            enabled: true, rounds: 1,
            when_files_changed: [ "app/frontend/**/*", "plugins/**/app/frontend/**/*" ],
            seed_notes: nil
          )
        )
      )
      implement_run.update!(
        agent_diff: <<~DIFF,
          diff --git a/plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx b/plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx
          +<div>parent stack UI change</div>
          diff --git a/app/services/step_dispatcher.rb b/app/services/step_dispatcher.rb
          +dispatch_ready_siblings
        DIFF
        step_agent_diff: <<~DIFF
          diff --git a/app/services/step_dispatcher.rb b/app/services/step_dispatcher.rb
          +dispatch_ready_siblings
        DIFF
      )
    end

    it "skips visual review based on this step's scoped diff" do
      expect(handler).not_to receive(:run_agent)

      handler.call

      expect(workflow.reload.artifact("visual_review_iterations").last).to include(
        "iteration" => review_step.iteration,
        "verdict" => "skipped"
      )
    end
  end

  context "when when_files_changed includes the plugin frontend globs and the diff is plugin-only (JOB-3662 regression)" do
    before do
      allow(handler.send(:workspace)).to receive(:base_ref).and_return("origin/main")
      allow(SyrusYml).to receive(:load_repo).with(Pathname.new("/tmp/workspace")).and_return(
        SyrusYml::Config.new(
          prepare: nil, grade: nil, hooks: nil, adversarial_review: nil, agent_insight: nil,
          coverage: nil, formatters: [], generated: [], deployment_stages: [], preview: nil, review_plan: false, deploy: nil,
          delivery: nil, raw_delivery: nil, approval: nil, external_prs: nil, project: nil, targets: [],
          visual_review: SyrusYml::VisualReviewConfig.new(
            enabled: true, rounds: 1,
            when_files_changed: [
              "app/frontend/**/*",
              "app/views/**/*",
              "plugins/**/app/frontend/**/*",
              "plugins/**/app/views/**/*"
            ],
            seed_notes: nil
          )
        )
      )
      allow(GitRunner).to receive(:new).and_return(instance_double(GitRunner).tap do |git|
        allow(git).to receive(:run).with("diff", "--name-only", anything, chdir: "/tmp/workspace")
                                    .and_return(
                                      "plugins/mysql_db_browser/app/frontend/routes/DbBrowser.tsx\n" \
                                      "plugins/mysql_db_browser/app/frontend/components/TablesPanel.tsx\n"
                                    )
      end)
      implement_run.update!(
        agent_diff: "diff --git a/plugins/mysql_db_browser/app/frontend/routes/DbBrowser.tsx b/plugins/mysql_db_browser/app/frontend/routes/DbBrowser.tsx\n+ui\n",
        step_agent_diff: "diff --git a/plugins/mysql_db_browser/app/frontend/routes/DbBrowser.tsx b/plugins/mysql_db_browser/app/frontend/routes/DbBrowser.tsx\n+ui\n"
      )
    end

    it "invokes the agent instead of skipping via the pre-filter" do
      expect(handler).to receive(:run_agent) do |prompt: nil, **|
        workflow.set_artifact!("visual_review_iterations", [
          { "iteration" => review_step.iteration, "critique" => "OK.", "verdict" => "approved" }
        ])
      end

      handler.call
    end
  end

  context "in a pr_comment feedback workflow" do
    let(:user) { Factories.user(github_token: "ghp_test") }
    let(:repository) { Factories.repository(user: user) }
    let(:feedback_job) do
      Factories.job_record(
        user: user,
        repository: repository,
        state: "open",
        issue_title: "Feedback job",
        issue_body: "Original task body."
      )
    end
    let(:feedback_workflow) do
      Workflow.create!(
        job: feedback_job,
        trigger_kind: "pr_comment",
        agent_provider: "claude",
        chain_template: []
      )
    end
    let(:respond_step) do
      Step.create!(workflow: feedback_workflow, kind: "respond", position: 1, iteration: 1,
                   state: "succeeded", loop_id: "fb-loop-1")
    end
    let(:respond_run) do
      Run.create!(job: feedback_job, step: respond_step, trigger_kind: "pr_comment", state: "succeeded",
                  agent_diff: "diff --git a/foo.rb b/foo.rb\n+# addressed feedback\n")
    end
    let(:fb_review_step) do
      Step.create!(workflow: feedback_workflow, kind: "visual_review", position: 2, iteration: 1,
                   loop_id: "fb-loop-1")
    end
    let(:fb_run) { Run.create!(job: feedback_job, step: fb_review_step, trigger_kind: "pr_comment") }
    let(:fb_handler) { described_class.new(fb_run) }

    before do
      fake_ws = instance_double(WorkflowWorkspace, setup: true, path: Pathname.new("/tmp/workspace"))
      allow(fb_handler).to receive(:workspace).and_return(fake_ws)
      allow(SyrusYml).to receive(:load_repo).with(Pathname.new("/tmp/workspace")).and_raise(Errno::ENOENT)
      respond_run
      feedback_workflow.set_artifact!("pr_comments", [
        { "author" => "alice", "body" => "The banner looks broken on mobile.", "path" => nil, "line" => nil }
      ])
    end

    it "reads the respond step diff, not an implement diff" do
      expect(fb_handler).to receive(:run_agent) do |prompt: nil, **|
        expect(prompt).to include("addressed feedback")
        expect(prompt).to include("respond step")
        feedback_workflow.set_artifact!("visual_review_iterations", [
          { "iteration" => 1, "critique" => "Fine.", "verdict" => "approved" }
        ])
      end

      fb_handler.call
    end

    it "includes the PR feedback context and workflow kind in the prompt" do
      expect(fb_handler).to receive(:run_agent) do |prompt: nil, **|
        expect(prompt).to include("PR comment feedback workflow")
        expect(prompt).to include("alice")
        expect(prompt).to include("The banner looks broken on mobile.")
        feedback_workflow.set_artifact!("visual_review_iterations", [
          { "iteration" => 1, "critique" => "Fine.", "verdict" => "approved" }
        ])
      end

      fb_handler.call
    end
  end
end
