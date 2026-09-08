module DiffReviewVersions
  class Creator
    def self.call(job:, base_sha:, head_sha:, files:, truncated: false, base_ref: nil, head_ref: nil, workflow: nil, run: nil, trigger_kind: nil, label: nil, reason: nil, metadata: {})
      new(
        job: job,
        base_sha: base_sha,
        head_sha: head_sha,
        files: files,
        truncated: truncated,
        base_ref: base_ref,
        head_ref: head_ref,
        workflow: workflow,
        run: run,
        trigger_kind: trigger_kind,
        label: label,
        reason: reason,
        metadata: metadata
      ).call
    end

    def initialize(job:, base_sha:, head_sha:, files:, truncated:, base_ref:, head_ref:, workflow:, run:, trigger_kind:, label:, reason:, metadata:)
      @job = job
      @base_sha = base_sha.to_s.strip.presence
      @head_sha = head_sha.to_s.strip.presence
      @files = files
      @truncated = truncated == true
      @base_ref = base_ref
      @head_ref = head_ref
      @workflow = workflow
      @run = run
      @trigger_kind = trigger_kind
      @label = label
      @reason = reason
      @metadata = metadata
    end

    def call
      return nil if @base_sha.blank? || @head_sha.blank?

      @job.with_lock do
        existing_version = @job.diff_review_versions
                               .where(base_sha: @base_sha, head_sha: @head_sha)
                               .latest_first
                               .first
        return existing_version if existing_version

        @job.diff_review_versions.find_or_create_by!(
          base_sha: @base_sha,
          head_sha: @head_sha,
          source_key: source_key
        ) do |version|
          version.version_index = DiffReviewVersion.next_index_for(@job)
          version.workflow = @workflow
          version.run = @run
          version.base_ref = @base_ref
          version.head_ref = @head_ref
          version.trigger_kind = @trigger_kind.to_s.presence || @workflow&.trigger_kind || @run&.trigger_kind
          version.label = @label.to_s.presence || DiffReviewVersions::Labeler.call(
            job: @job,
            workflow: @workflow,
            run: @run,
            trigger_kind: version.trigger_kind
          )
          version.reason = @reason
          version.truncated = @truncated
          version.files_snapshot = normalized_files
          version.metadata = normalized_metadata
        end
      end
    end

    private

    def source_key
      @source_key ||= [
        "workflow", @workflow&.id || "none",
        "run", @run&.id || "none"
      ].join(":")
    end

    def normalized_files
      Array(@files).map do |file|
        {
          "path" => value_for(file, :path).to_s,
          "status" => value_for(file, :status).to_s,
          "additions" => value_for(file, :additions).to_i,
          "deletions" => value_for(file, :deletions).to_i,
          "patch" => value_for(file, :patch)
        }
      end
    end

    def normalized_metadata
      @metadata.is_a?(Hash) ? @metadata : {}
    end

    def value_for(file, key)
      return file[key] if file.is_a?(Hash) && file.key?(key)
      return file[key.to_s] if file.is_a?(Hash)

      file.public_send(key) if file.respond_to?(key)
    end
  end
end
