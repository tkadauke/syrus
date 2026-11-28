module Coworkers
  class RegressionProof
    Result = Data.define(:proven, :reason) { def proven? = proven }

    def self.call(job) = new(job).call

    def initialize(job)
      @job = job
    end

    def call
      workflow = job.latest_workflow
      version = job.diff_review_versions.all_changes.latest_first.first
      head = workflow && Syrus::Host::ImmutableReviewHeadBarrier.reviewed_head_sha(workflow)
      cached = workflow&.artifact("coworker_regression_proof").to_h
      if cached["head_sha"] == head && cached["base_sha"] == version&.base_sha
        return Result.new(cached["proven"] == true, cached["reason"])
      end

      paths = added_spec_paths(version)
      grader = regression_grader(workflow)
      command = focused_command(paths)
      return Result.new(false, "missing_regression_spec") if paths.empty? || grader.nil? || command.nil? || head.blank?

      retry_result = Syrus::Host::BaseRevisionRetry.call(workflow:, grader_step: grader, base_sha: version.base_sha,
        command:, require_candidate_pass: true, candidate_files: paths, require_failed_test_evidence: true,
        log: ->(message) { Rails.logger.info(message) })
      proven = retry_result.ran && retry_result.inherited
      if retry_result.ran
        workflow.set_artifact!("coworker_regression_proof", {
          "head_sha" => head, "base_sha" => version.base_sha, "spec_paths" => paths,
          "proven" => proven, "reason" => retry_result.reason
        })
      end
      Result.new(proven, retry_result.reason)
    end

    private

    attr_reader :job

    def regression_grader(workflow)
      workflow&.steps&.where(kind: "grader", state: "succeeded")&.reorder(position: :desc, id: :desc)&.find do |step|
        step.details.to_h["base_retry"].present?
      end
    end

    def added_spec_paths(version)
      Array(version&.files_snapshot).filter_map do |file|
        path = file["path"].to_s
        path if file["status"].to_s == "added" && path.match?(%r{(?:\A|/)(?:spec|test)/})
      end
    end

    def focused_command(paths)
      quoted = paths.map { |path| Shellwords.escape(path) }.join(" ")
      return "bundle exec rspec #{quoted}" if paths.all? { |path| path.end_with?("_spec.rb") }
      return "npm test -- --run #{quoted}" if paths.all? { |path| path.match?(/\.(?:test|spec)\.[cm]?[jt]sx?\z/) }

      nil
    end
  end
end
