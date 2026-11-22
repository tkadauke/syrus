require "json"
require "net/http"
require "openssl"
require "uri"

class PluginRegistryPackageFetcher
  Error = Class.new(StandardError)
  Package = Struct.new(:archive, :signature, :name, :version, :registry, :trust_store, keyword_init: true)
  MAX_ARCHIVE_BYTES = Syrus::PluginPackage::Validator::MAX_TOTAL_SIZE
  MAX_SIGNATURE_BYTES = 1.megabyte

  def initialize(index_root: WorkflowWorkspace.data_root.join("plugin-registry", "index"), client: nil, search: nil)
    @index_root = Pathname.new(index_root)
    @client = client
    @search = search
  end

  def fetch(name:, version: nil, registry: nil)
    registry_entry = @client ? @client.entry(name:, version:) : @search&.resolve(name:, version:, registry:)
    client = registry_entry && (@client || @search.client_for(registry_entry))
    root = client && !@client ? client.index_root : @index_root
    path = registry_entry ? root.join(name, "#{registry_entry.version}.json") : index_path(name, version)
    metadata = JSON.parse(File.read(path))
    raise Error, "registry entry name does not match requested plugin" unless metadata.fetch("name") == name
    indexed_version = path.basename(".json").to_s
    raise Error, "registry entry version does not match its index path" unless metadata.fetch("version") == indexed_version

    archive = download_and_verify(metadata.fetch("package_url", metadata["artifact_url"]), metadata["package_digest"])
    signature = download(metadata.fetch("signature_url"), limit: MAX_SIGNATURE_BYTES)
    client&.activate_trust_store!
    Package.new(archive: StringIO.new(archive), signature:, name:, version: indexed_version,
      registry: @client ? nil : client&.source,
      trust_store: @client ? Syrus::PluginPackage::TrustStore.cached : client&.cached_trust_store)
  rescue Errno::ENOENT
    raise Error, "plugin release is not present in the registry index: #{name}#{"@#{version}" if version.present?}"
  rescue JSON::ParserError, KeyError => error
    raise Error, "invalid plugin registry entry: #{error.message}"
  end

  private

  def download_and_verify(url, expected_digest)
    body = download(url, limit: MAX_ARCHIVE_BYTES)
    if expected_digest.present? && Digest::SHA256.hexdigest(body) != expected_digest.delete_prefix("sha256:")
      raise Error, "plugin registry package digest does not match the index"
    end
    body
  end

  def index_path(name, version)
    raise Error, "invalid registry plugin name" unless name.match?(/\A[a-z][a-z0-9_]*\z/)

    directory = @index_root.join(name)
    if version.present?
      raise Error, "invalid registry plugin version" unless version.match?(/\A[0-9A-Za-z][0-9A-Za-z.+_-]*\z/)
      return directory.join("#{version}.json")
    end

    candidates = directory.glob("*.json")
    candidates.max_by { |path| Gem::Version.new(path.basename(".json").to_s) } || directory.join("missing.json")
  rescue ArgumentError => error
    raise Error, "invalid version in plugin registry index: #{error.message}"
  end

  def download(url, limit:)
    uri = URI.parse(url)
    raise Error, "plugin registry artifacts must use HTTPS" unless uri.is_a?(URI::HTTPS)
    raise Error, "plugin registry artifact host is not permitted" unless SsrfGuard.safe_host?(uri.host)

    body = +""
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 60) do |http|
      http.request(Net::HTTP::Get.new(uri.request_uri)) do |response|
        raise Error, "plugin registry download failed with HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
        raise Error, "plugin registry download is too large" if response["content-length"].to_i > limit

        response.read_body do |chunk|
          raise Error, "plugin registry download is too large" if body.bytesize + chunk.bytesize > limit

          body << chunk
        end
      end
    end
    body
  rescue URI::InvalidURIError, SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => error
    raise Error, "plugin registry download failed: #{error.message}"
  end
end
