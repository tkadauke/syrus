class CronTemplatesController < ApplicationController
  before_action :load_template, only: %i[ show edit update destroy ]

  def index
    @templates = Current.user.cron_templates.order(:name)
  end

  def show
    @repositories = Current.user.repositories.active.order(:owner, :name)
    @applied_tasks = @template.scheduled_tasks.alive.includes(:repository).order(created_at: :desc)
  end

  def new
    @template = Current.user.cron_templates.build(pr_pileup_policy: "skip", enabled: true)
  end

  def create
    @template = Current.user.cron_templates.build(cron_template_params)
    if @template.save
      redirect_to cron_template_path(@template), notice: "Template created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @template.update(cron_template_params)
      redirect_to cron_template_path(@template), notice: "Template updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @template.destroy!
    redirect_to cron_templates_path, notice: "Template deleted."
  end

  private

  def load_template
    @template = Current.user.cron_templates.find(params[:id])
  end

  def cron_template_params
    params.expect(cron_template: %i[ name description prompt cron_expression pr_pileup_policy enabled ])
  end
end
