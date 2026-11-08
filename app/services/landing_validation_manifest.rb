# SHA-bound validation manifest: the evidence a landing decision consumed,
# in the same vocabulary main grading later uses.
#
# Written by Steps::GraderCollect when a landing-phase grade passes, one per
# Workflow, under ARTIFACT_KEY. It records the exact integration/head SHA,
# the source snapshot, one entry per grader target (typed GraderOutcome plus
# the command/environment/input fingerprints and whether failure-or-pass
# evidence exists), and the CI-phase target set that main grading will select
# for the same diff (so the two can be compared without reading logs).
#
# Three consumers:
#   * .verify / .evidence_for -- the landing gate. A required result that is
#     missing, inconclusive, infrastructure-exhausted, from another SHA, or
#     without evidence blocks landing with an actionable reason.
#   * .compare_with_main -- main grading attributes every selected target to
#     matching pre-merge evidence or an explicit post-merge delta.
#   * .diagnostics -- operator API/UI payload; no raw-log archaeology.
class LandingValidationManifest
  ARTIFACT_KEY = "landing_validation_manifest".freeze
  CI_TARGET_SET_ARTIFACT_KEY = "landing_ci_phase_target_set".freeze
  PARITY_ARTIFACT_KEY = "main_grading_parity".freeze
  VERSION = 1

  # Result is an acceptable landing outcome only when conclusive-green.
  # Everything else blocks and names its reason.
  BLOCKER_CODES = %w[
    manifest_missing
    sha_mismatch
    required_result_missing
    required_result_inconclusive
    required_result_infrastructure_failed
    required_result_failed
    required_result_cancelled
    required_evidence_missing
    source_snapshot_mismatch
  ].freeze

  Blocker = Data.define(:code, :message, :target) do
    def to_h = { "code" => code, "message" => message, "target" => target }.compact
  end

  Verdict = Data.define(:ok, :binding, :manifest, :blockers) do
    def ok? = ok

    def reason
      return nil if ok?

      blockers.map(&:message).join("; ")
    end
  end

  class << self
    # --- building -----------------------------------------------------

    def build(workflow:, head_sha:, tree_sha:, base_sha:, base_ref:, grader_steps:, carried_forward: [], target_health_skipped: [])
      targets = grader_steps.map { |grader| step_entry(grader, head_sha) }
      targets.concat(Array(carried_forward).map { |entry| reused_entry(entry, "carried_forward", head_sha) })
      targets.concat(Array(target_health_skipped).map { |entry| reused_entry(entry, "target_health", head_sha) })

      {
        "version" => VERSION,
        "head_sha" => head_sha.to_s.presence,
        "tree_sha" => tree_sha.to_s.presence,
        "base_sha" => base_sha.to_s.presence,
        "base_ref" => base_ref.to_s.presence,
        "trigger_kind" => workflow.trigger_kind,
        "phase" => workflow.artifact("grade_phase").presence,
        "grader_fingerprint" => workflow.artifact(GraderConclusionCache::ARTIFACT_FINGERPRINT_KEY).presence,
        "changed_files_fingerprint" => workflow.artifact("grade_plan_changed_files_fingerprint").presence,
        "source_snapshot" => source_snapshot_for(grader_steps),
        "targets" => targets,
        "ci_phase_target_set" => workflow.artifact(CI_TARGET_SET_ARTIFACT_KEY),
        "recorded_at" => Time.current.iso8601
      }.compact
    end

    def record!(workflow:, **attrs)
      manifest = build(workflow: workflow, **attrs)
      workflow.set_artifact!(ARTIFACT_KEY, manifest)
      manifest
    end

    # Re-binds an existing manifest to a new SHA when the operator-trusted
    # clean-rebase carry-forward moved the validation. The original SHA is
    # kept so the diagnostics never pretend the new SHA ran the graders.
    def carry_forward!(workflow:, manifest:, head_sha:, tree_sha:, base_sha:, base_ref:)
      carried = manifest.to_h.merge(
        "head_sha" => head_sha.to_s,
        "tree_sha" => tree_sha.to_s.presence,
        "base_sha" => base_sha.to_s.presence,
        "base_ref" => base_ref.to_s.presence,
        "carried_from_sha" => manifest["carried_from_sha"].presence || manifest["head_sha"],
        "binding" => "clean_rebase_carry_forward",
        "recorded_at" => Time.current.iso8601
      ).compact
      workflow.set_artifact!(ARTIFACT_KEY, carried)
      carried
    end

    # --- verification -------------------------------------------------

    def verify(manifest, expected_sha:, expected_snapshot_sha: nil)
      return blocked("manifest_missing", "no landing validation manifest recorded for #{short(expected_sha)}; re-run landing validation") unless manifest.is_a?(Hash)

      binding = manifest["binding"].presence || "exact_head"
      blockers = []
      if manifest["head_sha"].to_s != expected_sha.to_s && binding == "exact_head"
        blockers << Blocker.new("sha_mismatch", "validation evidence is for #{short(manifest["head_sha"])}, not the landing SHA #{short(expected_sha)}", nil)
      end
      snapshot_sha = manifest.dig("source_snapshot", "source_sha")
      if snapshot_sha.present? && binding == "exact_head" && snapshot_sha != expected_sha.to_s
        blockers << Blocker.new("source_snapshot_mismatch", "graders ran against snapshot #{short(snapshot_sha)}, not #{short(expected_sha)}", nil)
      end

      required = Array(manifest["targets"]).select { |target| target["required"] }
      blockers << Blocker.new("required_result_missing", "manifest records no required grader results", nil) if required.empty?
      required.each { |target| blockers.concat(target_blockers(target, expected_sha, binding)) }

      Verdict.new(blockers.empty?, binding, manifest, blockers)
    end

    # Finds the manifest that justifies landing `sha` for this Job, trying
    # the exact head, then an identical tree, then (only when the repository
    # opted in) a clean-rebase carry-forward recorded against `sha`.
    def evidence_for(job:, sha:, tree_sha: nil)
      manifests = job.workflows.reorder(id: :desc).filter_map do |workflow|
        manifest = workflow.artifact(ARTIFACT_KEY)
        [ workflow, manifest ] if manifest.is_a?(Hash)
      end
      return verify(nil, expected_sha: sha) if manifests.empty?

      exact = manifests.find { |_, manifest| manifest["head_sha"] == sha.to_s }
      return verify(exact.last, expected_sha: sha) if exact

      if tree_sha.present?
        same_tree = manifests.find { |_, manifest| manifest["tree_sha"].present? && manifest["tree_sha"] == tree_sha.to_s }
        return verify(same_tree.last.merge("binding" => "same_tree"), expected_sha: sha) if same_tree
      end

      stale = manifests.first.last
      blocked(
        "sha_mismatch",
        "validation evidence is for #{short(stale["head_sha"])}, not the landing SHA #{short(sha)}; the branch moved after grading",
        manifest: stale
      )
    end

    # Returns the Verdict; callers decide how to fail.
    def gate(job:, sha:, tree_sha: nil, workflow: nil)
      verdict = evidence_for(job: job, sha: sha, tree_sha: tree_sha)
      workflow&.set_artifact!("landing_parity_gate", gate_payload(verdict, sha))
      verdict
    end

    # --- main grading parity -----------------------------------------

    # `selections` are Steps::GraderFanout::TARGET_SELECTIONS_ARTIFACT_KEY
    # entries recorded by the main grader workflow.
    def compare_with_main(manifest:, selections:, main_sha:)
      selected = Array(selections).select { |entry| entry["affected"] }
      return { "status" => "no_manifest", "main_sha" => main_sha, "attributed" => [], "deltas" => selected.map { |e| delta(e, "no_pre_merge_evidence") } } unless manifest.is_a?(Hash)

      evidence = Array(manifest["targets"]).index_by { |target| target["target_label"] }
      attributed = []
      deltas = []
      selected.each do |entry|
        prior = evidence[entry["target_label"]]
        reason = mismatch_reason(prior, entry)
        if reason
          deltas << delta(entry, reason)
        else
          attributed << { "target_label" => entry["target_label"], "name" => entry["name"], "pre_merge_outcome" => prior["outcome"], "evidence_source" => prior["source"] }
        end
      end

      {
        "status" => deltas.empty? ? "matched" : "delta",
        "main_sha" => main_sha,
        "manifest_sha" => manifest["head_sha"],
        "attributed" => attributed,
        "deltas" => deltas
      }
    end

    def record_main_parity!(workflow:, manifest:, selections:, main_sha:)
      result = compare_with_main(manifest: manifest, selections: selections, main_sha: main_sha)
      workflow.set_artifact!(PARITY_ARTIFACT_KEY, result)
      result
    end

    # Manifest that justified the merge which produced `main_sha`, found by
    # the landed SHA recorded on the Job (or the train's integration SHA).
    def manifest_for_landed_sha(repository:, sha:)
      return nil if sha.blank?

      job = repository.jobs.where(landed_sha: sha).order(id: :desc).first
      return manifest_from_workflows(job.workflows) if job && manifest_from_workflows(job.workflows)

      landable = LandedCommit.where(sha: sha).order(id: :desc).first&.landable
      return nil unless landable.is_a?(MergeTrain)

      train_job_ids = landable.members.pluck(:job_id)
      workflows = Workflow.where(job_id: train_job_ids).reorder(id: :desc).select do |workflow|
        workflow.artifact("merge_train_id").to_s == landable.id.to_s
      end
      manifest_from_workflows(workflows)
    end

    # Targets the CI phase will select for main that the landing-phase
    # results do not cover. Surfaced before merge so they are run (by main
    # grading) and named, never silently assumed green.
    def ci_delta(manifest)
      return [] unless manifest.is_a?(Hash)

      covered = Array(manifest["targets"]).select { |t| t["outcome"] == GraderOutcome::PASSED }.to_set { |t| t["target_label"] }
      Array(manifest.dig("ci_phase_target_set", "targets")).select { |t| t["affected"] && !covered.include?(t["target_label"]) }
                                                              .map { |t| delta(t, "ci_phase_target_not_validated_pre_merge") }
    end

    # --- diagnostics --------------------------------------------------

    def diagnostics(workflow)
      manifest = workflow.artifact(ARTIFACT_KEY)
      gate = workflow.artifact("landing_parity_gate")
      parity = workflow.artifact(PARITY_ARTIFACT_KEY)
      return nil unless manifest.is_a?(Hash) || gate || parity

      {
        "manifest" => manifest.is_a?(Hash) ? summarize(manifest) : nil,
        "landing_gate" => gate,
        "main_parity" => parity
      }.compact
    end

    private

    def manifest_from_workflows(workflows)
      Array(workflows).each do |workflow|
        manifest = workflow.artifact(ARTIFACT_KEY)
        return manifest if manifest.is_a?(Hash)
      end
      nil
    end

    def summarize(manifest)
      {
        "head_sha" => manifest["head_sha"],
        "base_sha" => manifest["base_sha"],
        "binding" => manifest["binding"] || "exact_head",
        "carried_from_sha" => manifest["carried_from_sha"],
        "source_snapshot" => manifest["source_snapshot"],
        "recorded_at" => manifest["recorded_at"],
        "targets" => Array(manifest["targets"]).map { |t| t.slice("name", "target_label", "required", "outcome", "reason", "source", "has_evidence") },
        "ci_phase_target_count" => Array(manifest.dig("ci_phase_target_set", "targets")).size
      }
    end

    def gate_payload(verdict, sha)
      {
        "ok" => verdict.ok?,
        "sha" => sha.to_s,
        "binding" => verdict.binding,
        "blockers" => verdict.blockers.map(&:to_h),
        "post_merge_delta" => ci_delta(verdict.manifest),
        "checked_at" => Time.current.iso8601
      }
    end

    def blocked(code, message, manifest: nil)
      Verdict.new(false, nil, manifest, [ Blocker.new(code, message, nil) ])
    end

    def target_blockers(target, expected_sha, binding)
      label = target["name"].presence || target["target_label"]
      outcome = target["outcome"]
      case outcome
      when GraderOutcome::PASSED
        if binding == "exact_head" && target["source_sha"].present? && target["source_sha"] != expected_sha.to_s
          [ Blocker.new("sha_mismatch", "#{label} passed on #{short(target["source_sha"])}, not #{short(expected_sha)}", label) ]
        elsif !target["has_evidence"]
          [ Blocker.new("required_evidence_missing", "#{label} passed without command/environment fingerprints or a recorded command; cannot prove which semantics ran", label) ]
        else
          []
        end
      when GraderOutcome::INCONCLUSIVE
        [ Blocker.new("required_result_inconclusive", "#{label} was inconclusive (#{target["reason"]}); re-run it rather than landing on missing evidence", label) ]
      when GraderOutcome::INFRASTRUCTURE_FAILED
        [ Blocker.new("required_result_infrastructure_failed", "#{label} could not run (#{target["reason"]}); this is an infrastructure problem, not a code verdict -- retry validation", label) ]
      when GraderOutcome::TEST_FAILED
        [ Blocker.new("required_result_failed", "#{label} failed", label) ]
      when GraderOutcome::CANCELLED
        [ Blocker.new("required_result_cancelled", "#{label} was cancelled before producing a result", label) ]
      else
        [ Blocker.new("required_result_missing", "#{label} has no recorded outcome", label) ]
      end
    end

    def step_entry(grader, head_sha)
      details = grader.details.to_h
      result = GraderOutcome.for_step(grader)
      fingerprints = details["target_fingerprints"].to_h
      {
        "name" => details["name"],
        "target_label" => details["target_label"].presence || "//:grade/#{details["name"]}",
        "required" => !!details["required"],
        "outcome" => result.outcome,
        "reason" => result.reason,
        "source" => "ran",
        "source_sha" => details.dig("source_snapshot", "source_sha").presence || head_sha.to_s,
        "command_fingerprint" => fingerprints["command_fingerprint"],
        "environment_fingerprint" => fingerprints["environment_fingerprint"],
        "input_fingerprint" => fingerprints["input_fingerprint"],
        "has_evidence" => evidence?(details, fingerprints)
      }.compact
    end

    def reused_entry(entry, source, head_sha)
      entry = entry.to_h.stringify_keys
      fingerprints = entry["target_fingerprints"].to_h
      {
        "name" => entry["name"],
        "target_label" => entry["target_label"].presence || "//:grade/#{entry["name"]}",
        "required" => entry.key?("required") ? !!entry["required"] : true,
        "outcome" => GraderOutcome::PASSED,
        "reason" => source,
        "source" => source,
        "source_sha" => head_sha.to_s,
        "command_fingerprint" => fingerprints["command_fingerprint"],
        "environment_fingerprint" => fingerprints["environment_fingerprint"],
        "input_fingerprint" => fingerprints["input_fingerprint"],
        "has_evidence" => fingerprints["command_fingerprint"].present? && fingerprints["environment_fingerprint"].present?
      }.compact
    end

    def evidence?(details, fingerprints)
      (fingerprints["command_fingerprint"].present? && fingerprints["environment_fingerprint"].present?) ||
        (details["command"].present? && details["exit_code"].present?)
    end

    def source_snapshot_for(grader_steps)
      grader_steps.each do |grader|
        snapshot = grader.details.to_h["source_snapshot"]
        return snapshot.slice("source_sha", "tree_sha", "fingerprint") if snapshot.is_a?(Hash) && snapshot["source_sha"].present?
      end
      nil
    end

    # Why a main-selected target cannot reuse its pre-merge evidence.
    def mismatch_reason(prior, entry)
      return "not_selected_pre_merge" unless prior
      return "pre_merge_#{prior["outcome"]}" unless prior["outcome"] == GraderOutcome::PASSED

      fingerprints = entry["target_fingerprints"].to_h
      return "command_fingerprint_changed" if differs?(prior["command_fingerprint"], fingerprints["command_fingerprint"])
      return "environment_fingerprint_changed" if differs?(prior["environment_fingerprint"], fingerprints["environment_fingerprint"])

      nil
    end

    # A missing fingerprint on either side cannot prove parity.
    def differs?(left, right)
      left.blank? || right.blank? || left != right
    end

    def delta(entry, reason)
      { "target_label" => entry["target_label"], "name" => entry["name"], "reason" => reason }
    end

    def short(sha) = sha.to_s.first(7).presence || "unknown"
  end
end
