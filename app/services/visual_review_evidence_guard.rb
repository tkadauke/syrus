class VisualReviewEvidenceGuard
  VisualDiffResult = Data.define(:accepted_artifacts, :rejected_artifacts) do
    def accepted? = rejected_artifacts.empty?
    def rejected? = rejected_artifacts.any?
  end

  AUTH_PATH_PATTERN = %r{
    \A/
    (
      auth
      | login
      | log[_-]?in
      | session
      | sessions
      | sign[_-]?in
      | signin
      | users/sign_in
    )
    (?:/|\z)
  }ix
  ERROR_PATH_PATTERN = %r{
    \A/
    (
      401
      | 403
      | 404
      | 422
      | 500
      | error
      | errors
      | forbidden
      | not[_-]?found
      | unauthorized
    )
    (?:/|\z)
  }ix
  AUTH_TEXT_PATTERN = /\b(auth(?:entication)? required|log in|login|sign in|signin|session expired)\b/i
  ERROR_TEXT_PATTERN = /\b(application error|forbidden|internal server error|not found|page not found|unauthorized)\b/i
  ROUTE_PATTERN = /(?<![A-Za-z0-9_])\/[A-Za-z0-9][A-Za-z0-9_\-.\/]*/
  FILE_EXTENSION_PATTERN = /\.(?:css|erb|gif|html|jpe?g|js|jsx|json|md|png|rb|scss|ts|tsx|txt|ya?ml)\z/i

  def self.validate_visual_diff_after_artifacts(job:, artifacts:, prompt: nil)
    new(job: job, prompt: prompt, artifacts: artifacts).validate_visual_diff_after_artifacts
  end

  def initialize(job:, artifacts:, prompt: nil)
    @job = job
    @prompt = prompt
    @artifacts = Array(artifacts)
  end

  def validate_visual_diff_after_artifacts
    intended = intended_surface
    return VisualDiffResult.new(accepted_artifacts: @artifacts, rejected_artifacts: []) if intended.blank?
    return VisualDiffResult.new(accepted_artifacts: @artifacts, rejected_artifacts: []) if wall_surface?(path: intended, title: nil, text: nil)

    accepted = []
    rejected = []
    @artifacts.each do |artifact|
      if wall_artifact?(artifact)
        rejected << rejected_visual_diff_artifact(artifact, intended)
      else
        accepted << artifact
      end
    end

    VisualDiffResult.new(accepted_artifacts: accepted, rejected_artifacts: rejected)
  end

  private

  def wall_artifact?(artifact)
    page = artifact["page"].is_a?(Hash) ? artifact["page"] : {}
    payload = artifact["payload"].is_a?(Hash) ? artifact["payload"] : {}
    wall_surface?(
      path: page["path"] || payload.dig("page", "path"),
      title: page["title"] || payload.dig("page", "title") || artifact["title"],
      text: artifact["text"] || payload["text"] || payload["dom_text"] || payload["body_text"]
    )
  end

  def wall_surface?(path:, title:, text:)
    normalized_path = normalize_path(path)
    return true if normalized_path.match?(AUTH_PATH_PATTERN) || normalized_path.match?(ERROR_PATH_PATTERN)

    [ title, text ].compact_blank.any? do |value|
      value.to_s.match?(AUTH_TEXT_PATTERN) || value.to_s.match?(ERROR_TEXT_PATTERN)
    end
  end

  def intended_surface
    route = intended_route_candidates.find { |path| !wall_surface?(path: path, title: nil, text: nil) }
    return route if route
    return nil if intended_route_candidates.present?

    intended_title_candidates.find { |title| !wall_surface?(path: nil, title: title, text: nil) }
  end

  def intended_route_candidates
    @intended_route_candidates ||= source_texts.flat_map { |text| extract_routes(text) }.uniq
  end

  def intended_title_candidates
    @intended_title_candidates ||= @artifacts.filter_map do |artifact|
      artifact["title"].presence if artifact.is_a?(Hash)
    end.uniq
  end

  def source_texts
    [
      @job&.issue_title,
      @job&.issue_body,
      @prompt || @run&.prompt
    ].compact_blank
  end

  def extract_routes(text)
    text.to_s.scan(ROUTE_PATTERN).map { |match| normalize_path(match) }.select do |path|
      path.present? &&
        path != "/" &&
        !path.start_with?("/api/", "/rails/") &&
        !path.match?(FILE_EXTENSION_PATTERN)
    end
  end

  def normalize_path(value)
    path = value.to_s.strip
    path = URI.parse(path).request_uri if path.match?(/\Ahttps?:\/\//i)
    path = path.split("#", 2).first.to_s
    path = path.split("?", 2).first.to_s
    path = path.sub(/[.,;:]+\z/, "")
    path = path.gsub(%r{/+}, "/")
    path.presence || "/"
  rescue URI::InvalidURIError
    value.to_s.strip
  end

  def captured_surface_label(artifact)
    page = artifact["page"].is_a?(Hash) ? artifact["page"] : {}
    payload = artifact["payload"].is_a?(Hash) ? artifact["payload"] : {}
    payload_page = payload["page"].is_a?(Hash) ? payload["page"] : {}
    path = normalize_path(page["path"] || page["url"] || payload_page["path"] || payload_page["url"])
    title = (page["title"] || payload_page["title"]).to_s.strip
    title.present? ? "#{path.inspect} titled #{title.inspect}" : path.inspect
  end

  def rejected_visual_diff_artifact(artifact, intended)
    label = artifact["title"].presence || artifact["type"].presence || "untitled visual artifact"
    reason =
      "Rejected #{label.inspect}: captured #{captured_surface_label(artifact)} appears to be an auth/error screen, " \
      "but the changed surface appears to be #{intended.inspect}."
    artifact.merge("rejected_reason" => reason)
  end
end
