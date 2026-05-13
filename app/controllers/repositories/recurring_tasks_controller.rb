class Repositories::RecurringTasksController < ApplicationController
  before_action :load_repository
  before_action :load_task, only: %i[ update destroy ]

  def index
    @recurring_tasks = @repository.recurring_tasks.order(enabled: :desc, next_fire_at: :asc, created_at: :desc)
  end

  def update
    enabled = ActiveModel::Type::Boolean.new.cast(params[:enabled])
    @recurring_task.update!(enabled: enabled)
    redirect_to repository_recurring_tasks_path(@repository), notice: enabled ? "Recurring task enabled." : "Recurring task disabled."
  end

  def destroy
    @recurring_task.destroy!
    redirect_to repository_recurring_tasks_path(@repository), notice: "Recurring task deleted."
  end

  private

  def load_repository
    @repository = Current.user.repositories.find(params[:repository_id])
  end

  def load_task
    @recurring_task = @repository.recurring_tasks.find(params[:id])
  end
end
