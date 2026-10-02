module App
  class DiffReviewAnnotationsPayload
    EMPTY_PAYLOAD = {
      annotations: {},
      ranges: {},
      panels: [],
      sidebar_panels: [],
      actions: [],
      counts: [],
      sidebar_counts: []
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
      merge_ranges!(result[:ranges], payload[:ranges])
      result[:panels].concat(normalize_collection(payload[:panels] || payload[:cards]))
      result[:sidebar_panels].concat(normalize_collection(payload[:sidebar_panels]))
      result[:actions].concat(normalize_collection(payload[:actions]))
      result[:counts].concat(normalize_collection(payload[:counts]))
      result[:sidebar_counts].concat(normalize_collection(payload[:sidebar_counts]))
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

    def merge_ranges!(target, ranges)
      ranges.to_h.each do |path, entries|
        next if path.blank?

        normalized_entries = Array(entries).filter_map { |entry| normalized_range_entry(entry) }
        next if normalized_entries.empty?

        target[path.to_s] ||= []
        target[path.to_s].concat(normalized_entries)
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

    def normalized_range_entry(entry)
      normalized = normalized_entry(entry)
      return nil unless normalized

      side = normalized["side"].to_s
      return nil unless %w[old new].include?(side)

      start_line = normalized["start_line"] || normalized["startLine"] || normalized["line"]
      end_line = normalized["end_line"] || normalized["endLine"] || start_line
      start_line = Integer(start_line, exception: false)
      end_line = Integer(end_line, exception: false)
      return nil unless start_line&.positive?

      end_line = start_line unless end_line&.positive?
      normalized.merge(
        "side" => side,
        "start_line" => [ start_line, end_line ].min,
        "end_line" => [ start_line, end_line ].max
      )
    end
  end
end
