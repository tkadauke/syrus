require "fileutils"
require "json"
require "net/http"
require "open3"
require "uri"

class PluginRegistryClient
  Error = Class.new(StandardError)
  FORMAT_VERSION = 1
  Entry = Data.define(:name, :version, :description, :category, :author, :homepage, :license,
    :requires_syrus, :package_url, :package_digest, :signature_url, :publisher_key_fingerprint,
    :trust_label, :capability_summary, :revoked)
  Result = Data.define(:entries, :configured, :error, :stale)

  def initialize(url: ENV["SYRUS_PLUGIN_REGISTRY_URL"], cache_root: WorkflowWorkspace.data_root.join("plugin-registry"),
    syrus_version: SyrusVersion.release)
    @url = url.to_s.strip
    @cache_root = Pathname.new(cache_root)
    @syrus_version = syrus_version
  end

  def search(term = nil)
    return Result.new(entries: [], configured: false, error: nil, stale: false) if @url.empty?

    stale = false
    begin
      refresh!
    rescue Error => error
      return Result.new(entries: [], configured: true, error: error.message, stale: false) unless cached_index?
      stale = true
      refresh_error = error.message
    end
    entries = parse_entries.select { |entry| compatible?(entry) }.reject(&:revoked)
    query = term.to_s.downcase.strip
    if query.present?
      entries.select! do |entry|
        [ entry.name, entry.description, entry.category, entry.author ].any? { |value| value.to_s.downcase.include?(query) }
      end
    end
    Result.new(entries: entries.sort_by { |entry| [ entry.name, Gem::Version.new(entry.version) ] },
      configured: true, error: refresh_error, stale:)
  rescue Error, JSON::ParserError, KeyError, ArgumentError => error
    Result.new(entries: [], configured: true, error: "Malformed plugin registry: #{error.message}", stale:)
  end

  def entry(name:, version: nil)
    result = search
    raise Error, result.error if result.error && result.entries.empty?
    matches = result.entries.select { |candidate| candidate.name == name }
    matches.select! { |candidate| candidate.version == version } if version.present?
    matches.max_by { |candidate| Gem::Version.new(candidate.version) } ||
      raise(Error, "compatible plugin release is not present in the registry: #{name}#{"@#{version}" if version.present?}")
  end

  def index_root = @cache_root.join("index")

  private

  def refresh!
    FileUtils.mkdir_p(@cache_root)
    git_source? ? refresh_git! : refresh_http!
  rescue URI::InvalidURIError, SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => error
    raise Error, "Plugin registry is unreachable: #{error.message}"
  end

  def git_source? = @url.start_with?("git+") || @url.end_with?(".git")

  def refresh_git!
    url = @url.delete_prefix("git+")
    uri = URI.parse(url)
    raise Error, "Plugin registry git URL must use HTTPS" unless uri.is_a?(URI::HTTPS)
    raise Error, "Plugin registry git host is not permitted" unless SsrfGuard.safe_host?(uri.host)
    if index_root.join(".git").directory?
      _out, error, status = Open3.capture3("git", "-C", index_root.to_s, "pull", "--ff-only", "--quiet")
    else
      FileUtils.rm_rf(index_root) if index_root.exist?
      _out, error, status = Open3.capture3("git", "clone", "--depth", "1", "--quiet", url, index_root.to_s)
    end
    raise Error, "Plugin registry git fetch failed: #{error.strip}" unless status.success?
  end

  def refresh_http!
    base = URI.parse(@url)
    raise Error, "Plugin registry mirror must use HTTPS" unless base.is_a?(URI::HTTPS)
    raise Error, "Plugin registry mirror host is not permitted" unless SsrfGuard.safe_host?(base.host)
    FileUtils.mkdir_p(index_root)
    manifest = JSON.parse(fetch_http(base, "index.json"))
    validate_index!(manifest)
    ([ manifest.fetch("trust_store") ] + manifest.fetch("releases")).each { |path| fetch_http(base, path) }
  end

  def fetch_http(base, relative)
    path = safe_relative_path(relative)
    destination = index_root.join(path)
    FileUtils.mkdir_p(destination.dirname)
    uri = URI.join(@url.end_with?("/") ? @url : "#{@url}/", path)
    metadata_path = Pathname.new("#{destination}.http.json")
    metadata = metadata_path.exist? ? JSON.parse(metadata_path.read) : {}
    request = Net::HTTP::Get.new(uri.request_uri)
    request["If-None-Match"] = metadata["etag"] if metadata["etag"]
    request["If-Modified-Since"] = metadata["last_modified"] if metadata["last_modified"]
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) { |http| http.request(request) }
    return destination.read if response.is_a?(Net::HTTPNotModified) && destination.exist?
    raise Error, "Plugin registry request failed with HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    destination.write(response.body)
    metadata_path.write(JSON.generate("etag" => response["etag"], "last_modified" => response["last-modified"]))
    response.body
  end

  def parse_entries
    manifest = JSON.parse(index_root.join("index.json").read)
    validate_index!(manifest)
    trust = Syrus::PluginPackage::TrustStore.new(JSON.parse(index_root.join(safe_relative_path(manifest.fetch("trust_store"))).read))
    Syrus::PluginPackage::TrustStore.cache!(trust)
    manifest.fetch("releases").map do |relative|
      data = JSON.parse(index_root.join(safe_relative_path(relative)).read)
      validate_entry!(data, relative)
      fingerprint = data.fetch("publisher_key_fingerprint").downcase
      digest = data.fetch("package_digest").delete_prefix("sha256:")
      revoked = trust.revoked_keys.include?(fingerprint) ||
        trust.revoked_release?(name: data.fetch("name"), version: data.fetch("version"), digest:)
      publisher = trust.publisher(fingerprint)
      Entry.new(name: data.fetch("name"), version: data.fetch("version"), description: data.fetch("description"),
        category: data.fetch("category"), author: data.fetch("author"), homepage: data.fetch("homepage"),
        license: data.fetch("license"), requires_syrus: data.fetch("requires_syrus"),
        package_url: data.fetch("package_url"), package_digest: digest, signature_url: data.fetch("signature_url"),
        publisher_key_fingerprint: fingerprint, trust_label: publisher&.label || "community",
        capability_summary: data.fetch("capability_summary"), revoked:)
    end
  end

  def validate_index!(data)
    raise Error, "unsupported index format version" unless data.fetch("format_version") == FORMAT_VERSION
    raise Error, "releases must be an array" unless data.fetch("releases").is_a?(Array)
  end

  def validate_entry!(data, relative)
    %w[name version description category author homepage license requires_syrus package_url package_digest signature_url publisher_key_fingerprint trust_label_inputs capability_summary].each { |key| data.fetch(key) }
    raise Error, "plugin names must be publisher-prefixed" unless data.fetch("name").match?(/\A[a-z][a-z0-9]*_[a-z][a-z0-9_]*\z/)
    raise Error, "registry entry path does not match its name and version" unless relative == "#{data.fetch("name")}/#{data.fetch("version")}.json"
    Gem::Requirement.new(data.fetch("requires_syrus"))
  end

  def compatible?(entry)
    @syrus_version.nil? || Gem::Requirement.new(entry.requires_syrus).satisfied_by?(@syrus_version)
  end

  def safe_relative_path(path)
    value = path.to_s
    valid = value.match?(/\A[a-zA-Z0-9_.-]+(?:\/[a-zA-Z0-9_.-]+)*\z/) && !value.split("/").include?("..")
    raise Error, "invalid registry path" unless valid
    value
  end

  def cached_index? = index_root.join("index.json").file?
end
