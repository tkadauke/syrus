require "uri"

class IssueImageExtractor
  IMAGE_MARKDOWN = /!\[[^\]]*\]\(\s*(<[^>]+>|[^)\s]+)(?:\s+["'][^"']*["'])?\s*\)/.freeze

  def self.urls(markdown)
    new(markdown).urls
  end

  def initialize(markdown)
    @markdown = markdown.to_s
  end

  def urls
    @markdown.scan(IMAGE_MARKDOWN).filter_map do |match|
      normalize(match.first)
    end.uniq
  end

  private

  def normalize(raw_url)
    url = raw_url.to_s.strip
    url = url[1...-1] if url.start_with?("<") && url.end_with?(">")
    uri = URI.parse(url)
    return unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    uri.to_s
  rescue URI::InvalidURIError
    nil
  end
end
