class Workflow
  # Documents the expected schema for Workflow#artifacts["sccache_stats"]
  # (EPIC-251). Produced by Steps::Prepare and Steps::Grader after each
  # shell command they run, via `sccache --show-stats --stats-format=json`
  # against the compiler-cache masquerade baked into the worker image
  # (Dockerfile, worker-deps stage). A follow-up Job (build-cache-stats-ui)
  # reads this back to surface hit/miss trends on the Run/Job detail page —
  # no UI is built here.
  #
  # `--show-stats` reports the sccache daemon's CUMULATIVE counters since
  # the local server process started (not a delta for the single command
  # that just ran), so consecutive entries are running totals, not
  # per-command deltas. Consumers should diff adjacent entries if a
  # per-command figure is wanted.
  #
  # Shape: an array of entries, one per capture, in capture order:
  #   run_id:      Integer  — the Run the capture happened during
  #   step_kind:   String   — "prepare" | "grader"
  #   label:       String   — the command (prepare) or grader name (grader)
  #   iteration:   Integer  — Run#iteration
  #   captured_at: String (ISO8601)
  #   stats:       Hash     — raw parsed `sccache --show-stats --stats-format=json` output
  module SccacheArtifact
    ARTIFACT_KEY = "sccache_stats"

    module_function

    # Read the sccache stats array from a workflow. Returns [] if absent.
    def read(workflow)
      Array(workflow.artifact(ARTIFACT_KEY))
    end

    # Append one capture entry (persists).
    def record!(workflow, run:, step_kind:, label:, stats:)
      entry = {
        "run_id"      => run.id,
        "step_kind"   => step_kind.to_s,
        "label"       => label.to_s,
        "iteration"   => run.iteration,
        "captured_at" => Time.current.iso8601,
        "stats"       => stats
      }
      workflow.set_artifact!(ARTIFACT_KEY, read(workflow) + [ entry ])
      entry
    end
  end
end
