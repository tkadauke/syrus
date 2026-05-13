require "net/http"
require "tempfile"
require "uri"

class IngestIssueImagesJob < ApplicationJob
  queue_as :default

  MAX_BYTES = 20.megabytes
  MAX_REDIRECTS = 5
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 30

  class DownloadTooLarge < StandardError; end

  def perform(job_id)
    job = Job.find_by(id: job_id)
    return unless job

    IssueImageExtractor.urls(job.issue_body).each do |url|
      ingest_url(job, url)
    end
  end

  private

  def ingest_url(job, url)
    return if job.job_attachments.exists?(source_url: url)

    head = request(:head, URI.parse(url), headers_for(job, url))
    unless head.is_a?(Net::HTTPSuccess)
      Rails.logger.warn("[IngestIssueImagesJob] job ##{job.id}: HEAD #{url} returned #{head.code}; skipping")
      return
    end

    content_type = normalized_content_type(head["content-type"])
    unless image_content_type?(content_type)
      Rails.logger.warn("[IngestIssueImagesJob] job ##{job.id}: #{url} is #{content_type.inspect}; skipping")
      return
    end

    content_length = head["content-length"].to_i if head["content-length"].present?
    if content_length && content_length > MAX_BYTES
      Rails.logger.warn("[IngestIssueImagesJob] job ##{job.id}: #{url} is #{content_length} bytes; skipping")
      return
    end

    download_to_attachment(job, url, content_type)
  rescue DownloadTooLarge => e
    Rails.logger.warn("[IngestIssueImagesJob] job ##{job.id}: #{e.message}; skipping")
  rescue => e
    Rails.logger.warn("[IngestIssueImagesJob] job ##{job.id}: failed to ingest #{url}: #{e.class}: #{e.message}")
  end

  def download_to_attachment(job, url, content_type)
    uri = URI.parse(url)
    headers = headers_for(job, url)
    byte_size = 0

    Tempfile.create([ "syrus-issue-image-", extension_for(content_type) ]) do |file|
      response = request(:get, uri, headers)
      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.warn("[IngestIssueImagesJob] job ##{job.id}: GET #{url} returned #{response.code}; skipping")
        return
      end

      body = response.body.to_s
      byte_size = body.bytesize
      raise DownloadTooLarge, "#{url} exceeded #{MAX_BYTES} bytes" if byte_size > MAX_BYTES

      file.write(body)
      file.rewind
      attachment = job.job_attachments.create!(
        attachment_type: :uploaded_file,
        source_url: url,
        content_type: content_type,
        byte_size: byte_size
      )
      attachment.file.attach(
        io: file,
        filename: filename_for(url, content_type),
        content_type: content_type
      )
    end
  rescue ActiveRecord::RecordNotUnique
    # Another worker attached the same source between the existence
    # check and insert. Treat it as a successful dedup skip.
  end

  def request(method, uri, headers, redirects: MAX_REDIRECTS)
    raise ArgumentError, "too many redirects for #{uri}" if redirects.negative?

    response = Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == "https",
      open_timeout: OPEN_TIMEOUT,
      read_timeout: READ_TIMEOUT
    ) do |http|
      request = method == :head ? Net::HTTP::Head.new(uri) : Net::HTTP::Get.new(uri)
      headers.each { |key, value| request[key] = value }
      http.request(request)
    end

    if response.is_a?(Net::HTTPRedirection) && response["location"].present?
      redirected_uri = URI.join(uri, response["location"])
      redirected_headers = redirected_uri.host == uri.host ? headers : headers.except("Authorization")
      return request(method, redirected_uri, redirected_headers, redirects: redirects - 1)
    end

    response
  end

  def headers_for(job, url)
    headers = {
      "User-Agent" => GithubClient::USER_AGENT,
      "Accept" => "image/*,*/*;q=0.8"
    }
    token = github_asset_url?(url) ? GithubClient.for(repository: job.repository, user: job.user).access_token : nil
    headers["Authorization"] = "Bearer #{token}" if token.present?
    headers
  rescue => e
    Rails.logger.warn("[IngestIssueImagesJob] job ##{job.id}: could not build authenticated headers for #{url}: #{e.class}: #{e.message}")
    headers
  end

  def github_asset_url?(url)
    uri = URI.parse(url)
    host = uri.host.to_s.downcase
    host == "github.com" && uri.path.to_s.start_with?("/user-attachments/assets/")
  rescue URI::InvalidURIError
    false
  end

  def normalized_content_type(value)
    value.to_s.split(";").first.to_s.strip.downcase
  end

  def image_content_type?(content_type)
    content_type.start_with?("image/")
  end

  def filename_for(url, content_type)
    basename = File.basename(URI.parse(url).path.to_s)
    basename = "issue-image#{extension_for(content_type)}" if basename.blank? || basename == "/"
    basename
  rescue URI::InvalidURIError
    "issue-image#{extension_for(content_type)}"
  end

  def extension_for(content_type)
    case content_type
    when "image/jpeg" then ".jpg"
    when "image/png" then ".png"
    when "image/gif" then ".gif"
    when "image/webp" then ".webp"
    else ".img"
    end
  end
end
