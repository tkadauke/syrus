# Shared by the job and repository preview controllers.
module PreviewLogParams
  extend ActiveSupport::Concern

  private

  # `preview.url` carries a freshly signed access token on every render, which
  # would make every response look new; revalidate on everything else.
  def preview_stale?(payload)
    preview = payload[:preview]
    etag_payload = preview ? payload.merge(preview: preview.merge(url: preview[:url]&.sub(/\?token=.*\z/, ""))) : payload
    stale?(etag: etag_payload)
  end

  def preview_log_lines
    params.fetch(:lines, PreviewLogReader::DEFAULT_LINES).to_i.clamp(1, PreviewLogReader::MAX_LINES)
  end

  # `since` is the per-file byte-offset map the previous response's `size`
  # fields describe, JSON-encoded: {"log/development.log": 1234}.
  def preview_log_since
    raw = params[:since].presence
    return nil unless raw.is_a?(String)

    parsed = JSON.parse(raw)
    parsed.is_a?(Hash) ? parsed : nil
  rescue JSON::ParserError
    nil
  end

  def preview_log_json(log)
    { path: log.path, content: log.content, missing: log.missing, size: log.size, incremental: log.incremental }
  end
end
