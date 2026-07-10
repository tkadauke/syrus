class Workflow
  # Documents the expected schema for Workflow#artifacts["coverage"].
  # Produced by the coverage_analyze step; consumed by summarize, pr_open,
  # and the UI serializer.
  #
  # Shape:
  #   summary:           { "lines_pct" => Float, "branches_pct" => Float, "functions_pct" => Float }
  #   files:             { filepath => { "lines_pct" => Float, "branches_pct" => Float } }
  #   diff_annotations:  { filepath => { "12" => "covered"|"uncovered"|"not_executable" } }
  #   pr_delta:          { "covered" => Integer, "total" => Integer, "pct" => Float,
  #                        "uncovered_files" => [String] }
  #   threshold_miss:         Boolean
  #   threshold_miss_details: { "lines_pct" => Float, "threshold_lines" => Float,
  #                             "pr_delta_pct" => Float, "threshold_pr_lines" => Float }
  #   coverage_unavailable: Boolean
  #   sources_status:    [{ "artifact" => String, "found" => Boolean, "lines_pct" => Float }]
  #   hit_map_attached:  Boolean
  #   pr_comment_body:   String (markdown) — present when coverage.pr_comment: true;
  #                      consumed by Steps::PrOpen (initial) and Steps::CoveragePrComment
  #                      (subsequent workflows) to post/update the GitHub PR comment
  module CoverageArtifact
    ARTIFACT_KEY = "coverage"

    ANNOTATION_VALUES = %w[covered uncovered not_executable].freeze

    module_function

    # Read the coverage artifact hash from a workflow. Returns nil if absent.
    def read(workflow)
      workflow.artifact(ARTIFACT_KEY)
    end

    # Write the coverage artifact hash onto a workflow (persists).
    def write!(workflow, value)
      workflow.set_artifact!(ARTIFACT_KEY, value)
    end
  end
end
