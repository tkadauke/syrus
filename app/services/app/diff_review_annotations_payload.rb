module App
  class DiffReviewAnnotationsPayload
    EMPTY_PAYLOAD = {
      annotations: {},
      panels: [],
      actions: [],
      counts: []
    }.freeze

    def self.build(job:, user:, version:, base_sha:, head_sha:, files:)
      new(job: job, user: user, version: version, base_sha: base_sha, head_sha: head_sha, files: files).payload
    end

    def initialize(job:, user:, version:, base_sha:, head_sha:, files:)
      @job = job
      @user = user
      @version = version
      @base_sha = base_sha
      @head_sha = head_sha
      @files = files
    end

    def payload
      providers.each_with_object(empty_payload) do |provider, result|
        contribution = provider.review_annotations(
          job: @job,
          user: @user,
          version: @version,
          base_sha: @base_sha,
          head_sha: @head_sha,
          files: @files
        )
        merge_contribution!(result, contribution)
      rescue StandardError => e
        Rails.logger.warn("[DiffReviewAnnotationsPayload] #{provider}.review_annotations failed for #{@job.slug}: #{e.class}: #{e.message}")
      end
    end

    private

    def providers
      Syrus::PluginRegistry.providers_for(:diff_review_annotation_provider)
    end

    def empty_payload
      EMPTY_PAYLOAD.deep_dup
    end

    def merge_contribution!(result, contribution)
      payload = contribution.to_h.with_indifferent_access
      merge_annotations!(result[:annotations], payload[:annotations])
      result[:panels].concat(normalize_collection(payload[:panels] || payload[:cards]))
      result[:actions].concat(normalize_collection(payload[:actions]))
      result[:counts].concat(normalize_collection(payload[:counts]))
    end

    def merge_annotations!(target, annotations)
      annotations.to_h.each do |path, line_map|
        next if path.blank?

        file_annotations = (target[path.to_s] ||= {})
        line_map.to_h.each do |line, entries|
          next if line.blank?

          normalized_entries = normalize_collection(entries)
          next if normalized_entries.empty?

          file_annotations[line.to_s] ||= []
          file_annotations[line.to_s].concat(normalized_entries)
        end
      end
    end

    def normalize_collection(value)
      Array(value).filter_map do |entry|
        normalized_entry(entry)
      end
    end

    def normalized_entry(entry)
      case entry
      when Hash
        entry.deep_stringify_keys
      else
        nil
      end
    end
  end
end
