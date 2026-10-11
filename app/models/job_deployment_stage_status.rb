class JobDeploymentStageStatus < ApplicationRecord
  belongs_to :job

  validates :stage_name, presence: true
  validates :reached_at, presence: true
  validates :stage_name, uniqueness: { scope: :job_id }

  after_create_commit :recheck_dependent_jobs_waiting_on_stage

  private

  def recheck_dependent_jobs_waiting_on_stage
    JobDependency
      .where(
        depends_on_job_id: job_id,
        satisfaction_mode: "deployment_stage",
        required_deployment_stage_name: stage_name
      )
      .joins(:job)
      .merge(Job.open_threads)
      .includes(:job)
      .find_each { |dependency| dependency.job.start_pending_workflows_if_dependencies_satisfied! }
  end
end
