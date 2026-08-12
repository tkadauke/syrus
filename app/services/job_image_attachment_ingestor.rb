require "net/http"
require "stringio"
require "uri"

class JobImageAttachmentIngestor
  MAX_BYTES = 10.megabytes
  MAX_LINE_BYTES = 32.kilobytes
  MAX_URL_BYTES = 4.kilobytes
  ALLOWED_CONTENT_TYPES = %w[
    image/gif
    image/jpeg
    image/png
    image/webp
  ].freeze

  Result = Data.define(:attached, :skipped)
  Download = Data.define(:body, :content_type, :filename)

  def self.ingest_markdown_images(job:, markdown:)
    new(job).ingest_markdown_images(markdown)
  end

  def initialize(job)
    @job = job
  end

  def ingest_markdown_images(markdown)
    attached = 0
    skipped = 0

    image_urls(markdown).each do |url|
      if ingest_url(url)
        attached += 1
      else
        skipped += 1
      end
    end

    Result.new(attached: attached, skipped: skipped)
  end

  private

  def image_urls(markdown)
    markdown.to_s.each_line.flat_map { |line| urls_from_line(line) }.uniq
  end

  def urls_from_line(line)
    line = line.to_s.safe_byteslice(0, MAX_LINE_BYTES)
    urls = []
    offset = 0

    while (start = line.index("![", offset))
      alt_end = line.index("]", start + 2)
      break unless alt_end

      open = line.index("(", alt_end + 1)
      break unless open

      close = line.index(")", open + 1)
      break unless close

      raw_target = line[(open + 1)...close].to_s.strip
      raw_target = raw_target[1...-1] if raw_target.start_with?("<") && raw_target.end_with?(">")
      raw_target = raw_target.split(/[[:space:]]+/, 2).first.to_s.strip
      urls << raw_target.safe_byteslice(0, MAX_URL_BYTES) if raw_target.present?
      offset = close + 1
    end

    urls
  end

  def ingest_url(source_url)
    return false if @job.job_attachments.exists?(source_url: source_url)

    download = download_image(source_url)
    return false unless download

    attachment = @job.job_attachments.build(
      attachment_type: "uploaded_file",
      source_url: source_url,
      filename: download.filename,
      content_type: download.content_type,
      byte_size: download.body.bytesize
    )
    attachment.file.attach(
      io: StringIO.new(download.body),
      filename: download.filename,
      content_type: download.content_type,
      identify: false
    )
    attachment.save!
    true
  rescue StandardError => e
    Rails.logger.warn("[JobImageAttachmentIngestor] #{@job.slug}: skipped #{source_url}: #{e.class}: #{e.message}")
    false
  end

  def download_image(source_url, redirects: 3)
    uri = URI.parse(source_url)
    return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: 15, open_timeout: 5) do |http|
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "Syrus image ingestor"
      http.request(request)
    end

    if response.is_a?(Net::HTTPRedirection) && redirects.positive?
      location = response["location"].to_s
      return nil if location.blank?
      return download_image(URI.join(uri, location).to_s, redirects: redirects - 1)
    end

    return nil unless response.is_a?(Net::HTTPSuccess)
    return nil if response["content-length"].to_i > MAX_BYTES

    content_type = response.content_type.to_s.downcase
    return nil unless ALLOWED_CONTENT_TYPES.include?(content_type)

    body = response.body.to_s
    return nil if body.bytesize > MAX_BYTES

    Download.new(
      body: body,
      content_type: content_type,
      filename: filename_for(uri, content_type)
    )
  rescue ArgumentError, URI::InvalidURIError, SocketError, SystemCallError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.warn("[JobImageAttachmentIngestor] #{@job.slug}: skipped #{source_url}: #{e.class}: #{e.message}")
    nil
  end

  def filename_for(uri, content_type)
    basename = File.basename(uri.path.to_s)
    return basename if basename.present? && basename != "/" && basename != "."

    "image#{extension_for(content_type)}"
  end

  def extension_for(content_type)
    case content_type
    when "image/gif" then ".gif"
    when "image/jpeg" then ".jpg"
    when "image/png" then ".png"
    when "image/webp" then ".webp"
    else ".img"
    end
  end
end
