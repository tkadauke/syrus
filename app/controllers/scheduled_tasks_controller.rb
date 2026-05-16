class ScheduledTasksController < ApplicationController
  before_action :load_repository, only: %i[ new create ]
  before_action :load_task,       only: %i[ show edit update destroy pause resume fire_now ]

  def index
    tasks = ScheduledTask.alive.where(user: Current.user).includes(:repository)
    @active_tasks   = tasks.where(state: %w[ scheduled paused auto_paused ]).order(:created_at)
    @fired_one_shots = tasks.where(state: "fired").order(updated_at: :desc).limit(20)
    @archived_tasks  = ScheduledTask.archived.where(user: Current.user).includes(:repository).order(archived_at: :desc).limit(20)
  end

  def show
    @recent_jobs = @task.jobs.order(created_at: :desc).limit(20)
  end

  def new
    @task = @repository.scheduled_tasks.build(
      user: Current.user,
      kind: "cron",
      pr_pileup_policy: "skip"
    )
    if params[:from_template].present?
      @from_template = Current.user.cron_templates.find_by(id: params[:from_template])
      if @from_template
        @task.assign_attributes(
          name: @from_template.name,
          prompt: @from_template.prompt,
          cron_expression: @from_template.cron_expression,
          pr_pileup_policy: @from_template.pr_pileup_policy,
          cron_template: @from_template
        )
      end
    end
  end

  def create
    @task = @repository.scheduled_tasks.build(scheduled_task_params)
    @task.user = Current.user
    if params[:from_template].present?
      template = Current.user.cron_templates.find_by(id: params[:from_template])
      @task.cron_template = template if template
    end
    if @task.save
      redirect_to scheduled_task_path(@task), notice: "Scheduled task created."
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @task.update(scheduled_task_params)
      redirect_to scheduled_task_path(@task), notice: "Scheduled task updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @task.soft_delete!
    redirect_to scheduled_tasks_path, notice: "Scheduled task archived."
  end

  def pause
    @task.pause!(reason: "operator")
    redirect_to scheduled_task_path(@task), notice: "Paused."
  end

  def resume
    @task.resume!
    redirect_to scheduled_task_path(@task), notice: "Resumed."
  end

  # Operator-triggered fire that bypasses the cron schedule. Useful
  # for testing a task without waiting and (per design discussions)
  # to give a future agentic-AI integration a way to trigger an
  # existing recurring task on demand. Honors pr_pileup_policy.
  def fire_now
    if @task.archived? || @task.fired?
      redirect_to scheduled_task_path(@task), alert: "Task isn't fireable in its current state."
      return
    end
    result = ScheduledTaskFire.new(@task).call
    if result.fired?
      redirect_to scheduled_task_path(@task), notice: "Fired (job ##{result.job.id})."
    else
      redirect_to scheduled_task_path(@task), notice: "Fire skipped: #{result.reason}."
    end
  rescue StandardError => e
    Rails.logger.warn("[ScheduledTasksController#fire_now] task ##{@task.id}: #{e.class}: #{e.message}")
    redirect_to scheduled_task_path(@task), alert: "Fire failed: #{e.message}"
  end

  private

  def load_repository
    @repository = Current.user.repositories.find(params[:repository_id])
  end

  def load_task
    @task = ScheduledTask.where(user: Current.user).find(params[:id])
  end

  def scheduled_task_params
    permitted = %i[ name prompt kind cron_expression fire_at pr_pileup_policy auto_approve_mode ]
    params.expect(scheduled_task: permitted)
  end
end
