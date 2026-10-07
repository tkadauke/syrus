module App
  class CoverageDiffAnnotationsPayload
    VALID_STATUSES = Workflow::CoverageArtifact::ANNOTATION_VALUES.freeze

    def self.build(job:, version:, files:)
      new(job: job, version: version, files: files).payload
    end

    def initialize(job:, version:, files:)
      @job = job
      @version = version
      @files = files
    end

    def payload
      artifact = relevant_coverage_artifact
      return {} unless artifact.is_a?(Hash)

      annotations = artifact["diff_annotations"]
      return {} unless annotations.is_a?(Hash)

      file_paths.each_with_object({}) do |path, result|
        lines = annotations[path]
        next unless lines.is_a?(Hash)

        filtered = lines.each_with_object({}) do |(line, status), line_result|
          status = status.to_s
          next unless VALID_STATUSES.include?(status)

          line_number = Integer(line, exception: false)
          next unless line_number&.positive?

          line_result[line_number.to_s] = status
        end
        result[path] = filtered if filtered.present?
      end
    end

    private

    def relevant_coverage_artifact
      relevant_workflows.each do |workflow|
        artifact = Workflow::CoverageArtifact.read(workflow)
        return artifact if relevant_artifact?(artifact)
      end
      nil
    end

    def relevant_workflows
      candidates = provenance_workflows
      candidates.concat(same_job_fallback_workflows) if same_job_fallback_allowed?

      candidates.compact.uniq
    end

    def provenance_workflows
      [ @version&.workflow, @version&.run&.workflow ]
    end

    def same_job_fallback_allowed?
      @version.nil? || @version.reviewable_all_changes?
    end

    def same_job_fallback_workflows
      @job.workflows.reorder(created_at: :desc, id: :desc).to_a
    end

    def relevant_artifact?(artifact)
      return false unless artifact.is_a?(Hash)

      annotations = artifact["diff_annotations"]
      return false unless annotations.is_a?(Hash)

      file_paths.any? { |path| annotations[path].is_a?(Hash) }
    end

    def file_paths
      @file_paths ||= Array(@files).filter_map do |file|
        path = file.respond_to?(:[]) ? (file[:path] || file["path"]) : nil
        path.to_s.presence
      end.uniq
    end
  end
end
