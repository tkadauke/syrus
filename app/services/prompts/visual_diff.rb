module Prompts
  class VisualDiff
    def initialize(job:, after_artifacts:, baseline_type:, base_branch:)
      @job = job
      @after_artifacts = after_artifacts
      @baseline_type = baseline_type
      @base_branch = base_branch
    end

    def to_s
      <<~PROMPT
        You are capturing baseline screenshots for a deferred before/after visual comparison.

        The workspace is checked out at the merge-base of #{@job.branch_name} and #{@base_branch}. This is the "before" revision. The existing visual-review screenshots below are the PR "after" revision.

        Start the preview, navigate to the same screens represented by these after screenshots, capture matching before screenshots, and call `submit_visual_artifact` once per matching baseline image.

        Use type "#{@baseline_type}" for every baseline screenshot. Use the exact same title as the paired after screenshot so Syrus can pair them; if a screen cannot be reproduced on the base revision, do not invent an image.

        After screenshots to reproduce:

        #{after_artifact_list}

        Always call `stop_preview` before finishing.
      PROMPT
    end

    private

    def after_artifact_list
      @after_artifacts.each_with_index.map do |artifact, index|
        title = artifact["title"].presence || "Screenshot #{index + 1}"
        url = artifact["image_url"]
        "- #{title}: #{url}"
      end.join("\n")
    end
  end
end
