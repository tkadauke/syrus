module Steps
  class VisualDiff < Base
    BASELINE_RENDERER_TYPE = :image_diff
    COMPARISON_RENDERER_TYPE = :before_after_visual_diff

    def call
      if auto_deferred? && obsolete_job_state?
        skip!("Job is already #{job.state}; automatic visual comparison is no longer useful.")
        return
      end

      workspace.setup
      record_base_revision!
      after_artifacts = Array(workflow.artifact("visual_diff_after_artifacts"))
      raise StepFailed, "no after screenshots available for visual_diff" if after_artifacts.empty?

      before_count = baseline_entries.size
      run.update!(prompt: prompt(after_artifacts)) if run.prompt.blank?
      run_agent(prompt: run.prompt, required_mcp_tools: %w[submit_visual_artifact])

      workflow.reload
      new_baselines = baseline_entries.drop(before_count)
      pairs = VisualDiffPairs.new(workflow: workflow, after_artifacts: after_artifacts, baseline_entries: new_baselines).pairs
      workflow.set_artifact!("visual_diff_pairs", pairs)

      if pairs.empty?
        skip!("No baseline screenshots were captured for the available after screenshots.")
        return
      end

      workflow.set_typed_artifact!(
        type: "visual_diff_comparison",
        title: "Before/after visual comparison",
        renderer_type: COMPARISON_RENDERER_TYPE,
        payload: {
          "base_revision" => workflow.artifact("visual_diff_base_revision"),
          "base_branch" => job.effective_base_branch,
          "head_revision" => job.branch_name,
          "pairs" => pairs
        }
      )
    end

    private

    def auto_deferred?
      workflow.artifact("visual_diff_source") == ::VisualDiffSubmission::AUTOMATIC_SOURCE
    end

    def obsolete_job_state?
      job.approved? || job.landing? || job.closed?
    end

    def skip!(reason)
      log("[visual_diff] skipped: #{reason}", kind: "system")
      workflow.set_artifact!("visual_diff_skipped_reason", reason)
    end

    def record_base_revision!
      sha = GitRunner.new.run("rev-parse", "HEAD", chdir: workspace.path.to_s).strip
      workflow.set_artifact!("visual_diff_base_revision", sha)
    end

    def prompt(after_artifacts)
      Prompts::VisualDiff.new(
        job: job,
        after_artifacts: after_artifacts,
        baseline_type: workflow.artifact("visual_diff_baseline_type").presence || ::VisualDiffSubmission::BASELINE_TYPE,
        base_branch: job.effective_base_branch
      ).to_s
    end

    def baseline_entries
      baseline_type = workflow.artifact("visual_diff_baseline_type").presence || ::VisualDiffSubmission::BASELINE_TYPE
      Array(workflow.artifact("typed_artifacts")).select do |entry|
        entry.is_a?(Hash) &&
          (entry["original_type"] == baseline_type || entry.dig("payload", "original_type") == baseline_type)
      end
    end

    class VisualDiffPairs
      def initialize(workflow:, after_artifacts:, baseline_entries:)
        @workflow = workflow
        @after_artifacts = after_artifacts
        @baseline_entries = baseline_entries
      end

      def pairs
        after_artifacts.each_with_index.filter_map do |after_artifact, index|
          baseline = baseline_for(after_artifact, index)
          next unless baseline

          {
            "title" => after_artifact["title"].presence || baseline["title"].presence || "Screenshot #{index + 1}",
            "before" => image_payload(baseline),
            "after" => after_artifact.slice("type", "title", "image_url", "content_type", "byte_size", "created_at")
          }
        end
      end

      private

      attr_reader :workflow, :after_artifacts, :baseline_entries

      def baseline_for(after_artifact, index)
        title = after_artifact["title"].to_s
        baseline_entries.find { |entry| entry["title"].to_s == title && title.present? } || baseline_entries[index]
      end

      def image_payload(entry)
        payload = entry["payload"].to_h
        {
          "type" => entry["type"],
          "title" => entry["title"],
          "image_url" => payload["image_url"],
          "content_type" => payload["content_type"],
          "byte_size" => payload["byte_size"],
          "created_at" => entry["created_at"]
        }
      end
    end
  end
end
