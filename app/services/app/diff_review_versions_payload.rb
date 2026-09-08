module App
  class DiffReviewVersionsPayload
    def self.index(job:)
      new(job: job).index
    end

    def self.show(version:)
      new(job: version.job, version: version).show
    end

    def initialize(job:, version: nil)
      @job = job
      @version = version
    end

    def index
      {
        job_id: @job.id,
        versions: @job.diff_review_versions.includes(:workflow, :run).ordered.map { |version| version_json(version) },
        latest_version_id: @job.diff_review_versions.latest_first.pick(:id)
      }
    end

    def show
      version_json(@version).merge(
        job_id: @job.id,
        default_ref: @job.repository.default_branch,
        files: Array(@version.files_snapshot).map { |file| file_json(file) },
        diff_error: nil
      )
    end

    private

    def version_json(version)
      {
        id: version.id,
        job_id: version.job_id,
        version_index: version.version_index,
        base_sha: version.base_sha,
        head_sha: version.head_sha,
        base_ref: version.base_ref,
        head_ref: version.head_ref,
        workflow_id: version.workflow_id,
        workflow: workflow_json(version.workflow),
        run_id: version.run_id,
        trigger_kind: version.trigger_kind,
        label: version.label,
        reason: version.reason,
        truncated: version.truncated,
        files_count: Array(version.files_snapshot).size,
        metadata: version.metadata || {},
        created_at: version.created_at&.iso8601
      }
    end

    def workflow_json(workflow)
      return nil unless workflow

      {
        id: workflow.id,
        trigger_kind: workflow.trigger_kind,
        state: workflow.state
      }
    end

    def file_json(file)
      {
        path: file["path"].to_s,
        status: file["status"].to_s,
        additions: file["additions"].to_i,
        deletions: file["deletions"].to_i,
        patch: file["patch"]
      }
    end
  end
end
