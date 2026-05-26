require "rails_helper"

RSpec.describe "Scheduled tasks", type: :request do
  let(:user)       { Factories.user }
  let(:other_user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  let(:valid_cron_attrs) do
    {
      name: "Weekly tests",
      kind: "cron",
      cron_expression: "0 9 * * 1",
      pr_pileup_policy: "skip",
      prompt: "Write missing tests."
    }
  end

  it "requires authentication on index" do
    get scheduled_tasks_path
    expect(response).to redirect_to(new_session_path).or redirect_to(new_user_path)
  end

  context "signed in" do
    before { sign_in_as(user) }

    describe "GET /repositories/:id/scheduled_tasks/new" do
      it "shows the cron section and hides fire_at for the default cron kind" do
        get new_repository_scheduled_task_path(repository)
        expect(response).to be_successful
        expect(response.body).to include('data-scheduled-task-form-target="cronSection" class=""')
        expect(response.body).to include('data-scheduled-task-form-target="oneShotSection" class="hidden"')
      end
    end

    describe "GET /scheduled_tasks/:id/edit" do
      it "hides cron section and shows fire_at for a one_shot task" do
        task = repository.scheduled_tasks.create!(
          user: user, name: "Once", kind: "one_shot",
          fire_at: 2.days.from_now, pr_pileup_policy: "skip",
          prompt: "Do something."
        )
        get edit_scheduled_task_path(task)
        expect(response).to be_successful
        expect(response.body).to include('data-scheduled-task-form-target="cronSection" class="hidden"')
        expect(response.body).to include('data-scheduled-task-form-target="oneShotSection" class=""')
      end

      it "shows cron section and hides fire_at for a cron task" do
        task = repository.scheduled_tasks.create!(user: user, **valid_cron_attrs)
        get edit_scheduled_task_path(task)
        expect(response).to be_successful
        expect(response.body).to include('data-scheduled-task-form-target="cronSection" class=""')
        expect(response.body).to include('data-scheduled-task-form-target="oneShotSection" class="hidden"')
      end
    end

    describe "GET /scheduled_tasks" do
      it "lists the user's active tasks" do
        repository.scheduled_tasks.create!(user: user, **valid_cron_attrs)
        get scheduled_tasks_path
        expect(response).to be_successful
        expect(response.body).to include("Weekly tests")
      end

      it "doesn't show another user's tasks" do
        other_repo = Factories.repository(user: other_user)
        other_repo.scheduled_tasks.create!(user: other_user, **valid_cron_attrs.merge(name: "Their task"))
        get scheduled_tasks_path
        expect(response.body).not_to include("Their task")
      end
    end

    describe "POST /repositories/:id/scheduled_tasks" do
      it "creates a cron task and redirects to its show page" do
        expect {
          post repository_scheduled_tasks_path(repository), params: {
            scheduled_task: valid_cron_attrs.merge(auto_approve_mode: "if_graders_pass")
          }
        }.to change { ScheduledTask.count }.by(1)
        task = ScheduledTask.last
        expect(response).to redirect_to(scheduled_task_path(task))
        expect(task.user).to eq(user)
        expect(task.repository).to eq(repository)
        expect(task.minute_offset).to be_between(0, 59)
        expect(task.auto_approve_mode).to eq("if_graders_pass")
      end

      it "rejects malformed cron expressions" do
        post repository_scheduled_tasks_path(repository),
             params: { scheduled_task: valid_cron_attrs.merge(cron_expression: "not cron") }
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("valid cron expression")
      end

      it "creates a one_shot task" do
        attrs = valid_cron_attrs.merge(kind: "one_shot", cron_expression: nil, fire_at: 2.days.from_now)
        expect {
          post repository_scheduled_tasks_path(repository), params: { scheduled_task: attrs }
        }.to change { ScheduledTask.count }.by(1)
        expect(ScheduledTask.last.kind).to eq("one_shot")
      end

      it "rejects creation against another user's repository" do
        other_repo = Factories.repository(user: other_user)
        post repository_scheduled_tasks_path(other_repo), params: { scheduled_task: valid_cron_attrs }
        expect(response).to have_http_status(:not_found)
      end
    end

    describe "PATCH /scheduled_tasks/:id" do
      it "updates the prompt" do
        task = repository.scheduled_tasks.create!(user: user, **valid_cron_attrs)
        patch scheduled_task_path(task), params: {
          scheduled_task: {
            prompt: "Updated standing instruction.",
            auto_approve_mode: "if_graders_pass_and_tagged_safe"
          }
        }
        expect(task.reload.prompt).to eq("Updated standing instruction.")
        expect(task.auto_approve_mode).to eq("if_graders_pass_and_tagged_safe")
      end

      it "shows the auto-approval picker and preview line" do
        task = repository.scheduled_tasks.create!(
          user: user,
          **valid_cron_attrs.merge(auto_approve_mode: "if_graders_pass")
        )

        get edit_scheduled_task_path(task)

        expect(response.body).to include("Auto-approval")
        expect(response.body).to include("If graders pass")
        expect(response.body).to include("repo-committed graders pass")
      end
    end

    describe "POST /scheduled_tasks/:id/pause and /resume" do
      let(:task) { repository.scheduled_tasks.create!(user: user, **valid_cron_attrs) }

      it "pauses an active task" do
        post pause_scheduled_task_path(task)
        expect(task.reload.state).to eq("paused")
      end

      it "resumes a paused task and clears the failure counter" do
        task.update_columns(state: "auto_paused", consecutive_failure_count: 5)
        post resume_scheduled_task_path(task)
        task.reload
        expect(task.state).to eq("scheduled")
        expect(task.consecutive_failure_count).to eq(0)
      end
    end

    describe "POST /scheduled_tasks/:id/fire_now" do
      it "fires the task immediately" do
        task = repository.scheduled_tasks.create!(user: user, **valid_cron_attrs)
        expect {
          post fire_now_scheduled_task_path(task)
        }.to change { task.jobs.count }.by(1)
        expect(response).to redirect_to(scheduled_task_path(task))
      end

      it "refuses to fire an archived task" do
        task = repository.scheduled_tasks.create!(user: user, **valid_cron_attrs)
        task.soft_delete!
        expect {
          post fire_now_scheduled_task_path(task)
        }.not_to change { task.jobs.count }
      end
    end

    describe "DELETE /scheduled_tasks/:id (soft delete)" do
      it "archives the task without removing the row" do
        task = repository.scheduled_tasks.create!(user: user, **valid_cron_attrs)
        delete scheduled_task_path(task)
        expect(task.reload.archived?).to be true
        expect(ScheduledTask.where(id: task.id)).to exist
      end
    end
  end
end
