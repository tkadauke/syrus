require "digest"
require "json"

module RuntimeImages
  module OciRegistry
    # Runtime Image Service provider backed by one operator-configured OCI
    # distribution registry.
    #
    # Operations are bound to credential roles: publish uses the builder
    # (push), resolve/inspect/pull use the worker (pull only), and
    # revoke/delete use the administrator. Every request is scoped to the
    # single repository derived from the namespace. Every manifest read or
    # written is re-hashed locally, so a digest is only trusted when the bytes
    # actually hash to it.
    #
    # Publish payload: { manifest: String, blobs: { "sha256:..." => String } }.
    # Retention is recorded by the service; the registry has no retention
    # concept, so #retain is intentionally a no-op.
    class Provider < RuntimeImages::Provider
      KEY = "oci_registry".freeze
      MANIFEST_TYPES = %w[
        application/vnd.oci.image.manifest.v1+json
        application/vnd.oci.image.index.v1+json
        application/vnd.docker.distribution.manifest.v2+json
        application/vnd.docker.distribution.manifest.list.v2+json
      ].freeze
      INDEX_TYPES = %w[application/vnd.oci.image.index.v1+json application/vnd.docker.distribution.manifest.list.v2+json].freeze
      TAG_FORMAT = /\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\z/

      attr_reader :configuration

      def initialize(configuration:, client: nil)
        @configuration = configuration
        @client = client || HttpClient.new(configuration)
        @layout = RepositoryLayout.new(prefix: configuration.repository_prefix)
      end

      def key = KEY

      def publish(request)
        payload = request.payload
        manifest = payload.is_a?(Hash) ? payload[:manifest] : nil
        raise ProviderError, "publish payload requires a :manifest" unless manifest.is_a?(String) && !manifest.empty?
        repo = repository(request.namespace)
        digest = sha256(manifest)

        (payload[:blobs] || {}).each { |blob_digest, bytes| push_blob(repo, blob_digest, bytes.to_s) }

        response = call(:builder, repo, :put, "/v2/#{repo}/manifests/#{digest}",
                        headers: { "Content-Type" => manifest_media_type(manifest) }, body: manifest)
        raise_for(response, "push manifest")
        verify_header_digest!(response, digest)
        tag(repo, digest, request.source_ref, manifest)
        PublishResult.new(digest: digest, locator: locator(request.namespace, digest), platform: request.platform)
      end

      def resolve(request)
        repo = repository(request.namespace)
        manifest, digest = fetch_manifest(repo, request.reference, role: :worker)
        digest = select_platform(repo, manifest, digest, request.platform)
        Resolution.new(digest: digest, locator: locator(request.namespace, digest), platform: request.platform)
      end

      def inspect_image(request)
        repo = repository(request.namespace)
        response = call(:worker, repo, :head, "/v2/#{repo}/manifests/#{request.digest}", headers: manifest_accept)
        return Inspection.new(digest: request.digest, locator: nil, platform: request.platform, present: false, metadata: {}) if response.status == 404
        raise_for(response, "inspect manifest")
        verify_header_digest!(response, request.digest)
        Inspection.new(digest: request.digest, locator: locator(request.namespace, request.digest), platform: request.platform,
                       present: true, metadata: { "media_type" => response.header("content-type"), "size" => response.header("content-length")&.to_i })
      end

      def pull(request)
        repo = repository(request.namespace)
        unless request.locator.nil? || @layout.owns_locator?(request.namespace, request.locator, host: configuration.host)
          raise NotPullable, "locator #{request.locator} is outside namespace #{request.namespace.name}"
        end
        fetch_manifest(repo, request.digest, role: :worker, expected: request.digest)
        PullResult.new(digest: request.digest, locator: locator(request.namespace, request.digest), platform: request.platform)
      end

      def revoke(request) = remove(request, "revoke")
      def delete(request) = remove(request, "delete")
      def retain(_request) = nil

      MAX_LISTED_TAGS = 1000
      TAG_PAGE_SIZE = 100

      # Digests reachable by a tag in the namespace's repository. Untagged
      # manifests (such as the children of an index) are not visible through
      # the tag API, so reconciliation only covers tagged images.
      def list(request)
        repo = repository(request.namespace)
        digests = []
        last = nil
        while digests.size < MAX_LISTED_TAGS
          query = "n=#{TAG_PAGE_SIZE}#{"&last=#{URI.encode_www_form_component(last)}" if last}"
          response = call(:worker, repo, :get, "/v2/#{repo}/tags/list?#{query}")
          return digests.uniq if response.status == 404
          raise_for(response, "list tags")
          tags = Array(JSON.parse(response.body.to_s)["tags"])
          break if tags.empty?
          tags.each { |tag| digests << tag_digest(repo, tag) }
          break if tags.size < TAG_PAGE_SIZE
          last = tags.last
        end
        digests.compact.uniq
      rescue JSON::ParserError
        raise ProviderError, "registry returned a tag list that is not valid JSON"
      end

      # A bearer token limited to pulling one namespace's repository, safe to
      # hand to a workload. Raises Unsupported when the registry cannot mint
      # scoped tokens, because the only alternative is exposing the
      # deployment credential.
      def worker_pull_grant(namespace)
        repo = repository(namespace)
        token, expires_at = @client.mint_token(role: :worker, repository: repo, actions: %w[pull])
        { registry: configuration.host, repository: repo, token: token, expires_at: expires_at, actions: %w[pull] }
      rescue HttpClient::AuthenticationFailed => e
        raise Unsupported, "cannot mint a scoped pull grant: #{e.message}"
      end

      private

      def remove(request, verb)
        repo = repository(request.namespace)
        response = call(:admin, repo, :delete, "/v2/#{repo}/manifests/#{request.digest}")
        return if response.status == 404
        raise Unsupported, "registry does not allow manifest deletion" if [405, 501].include?(response.status)
        raise_for(response, "#{verb} manifest")
      end

      def tag_digest(repo, tag)
        response = call(:worker, repo, :head, "/v2/#{repo}/manifests/#{URI.encode_www_form_component(tag)}", headers: manifest_accept)
        return nil unless response.success?
        digest = response.header("docker-content-digest")
        digest if digest.to_s.match?(RuntimeImage::DIGEST_FORMAT)
      end

      def push_blob(repo, digest, bytes)
        raise ProviderError, "blob digest #{digest.inspect} does not match its bytes" unless digest == sha256(bytes)
        head = call(:builder, repo, :head, "/v2/#{repo}/blobs/#{digest}")
        return if head.success?
        start = call(:builder, repo, :post, "/v2/#{repo}/blobs/uploads/", headers: { "Content-Length" => "0" })
        raise_for(start, "start blob upload")
        location = URI.parse(start.header("location").to_s)
        base = URI.parse(configuration.url)
        if location.host && [location.host, location.port] != [base.host, base.port]
          raise ProviderError, "registry returned an upload location on a different host"
        end
        query = URI.decode_www_form(location.query.to_s) << ["digest", digest]
        upload = call(:builder, repo, :put, "#{location.path}?#{URI.encode_www_form(query)}",
                      headers: { "Content-Type" => "application/octet-stream" }, body: bytes)
        raise_for(upload, "push blob")
        verify_header_digest!(upload, digest)
      end

      def tag(repo, digest, source_ref, manifest)
        return unless source_ref.to_s.match?(TAG_FORMAT)
        response = call(:builder, repo, :put, "/v2/#{repo}/manifests/#{source_ref}",
                        headers: { "Content-Type" => manifest_media_type(manifest) }, body: manifest)
        raise_for(response, "tag manifest")
        verify_header_digest!(response, digest)
      end

      def fetch_manifest(repo, reference, role:, expected: nil)
        response = call(role, repo, :get, "/v2/#{repo}/manifests/#{reference}", headers: manifest_accept)
        raise NotFound, "#{reference} not found in #{repo}" if response.status == 404
        raise_for(response, "read manifest")
        digest = sha256(response.body)
        expected ||= reference if reference.to_s.start_with?("sha256:")
        raise ProviderError, "registry returned manifest #{digest} for requested digest #{expected}" if expected && expected != digest
        verify_header_digest!(response, digest)
        [response.body, digest]
      end

      def select_platform(repo, manifest, digest, platform)
        parsed = JSON.parse(manifest)
        return digest unless INDEX_TYPES.include?(parsed["mediaType"])
        os, arch, variant = platform.to_s.split("/")
        child = Array(parsed["manifests"]).find do |m|
          p = m["platform"] || {}
          p["os"] == os && p["architecture"] == arch && (variant.nil? || p["variant"] == variant)
        end
        raise NotFound, "no #{platform} image in index #{digest}" unless child
        fetch_manifest(repo, child["digest"], role: :worker, expected: child["digest"]).last
      rescue JSON::ParserError
        raise ProviderError, "registry returned a manifest that is not valid JSON"
      end

      def call(role, repo, method, path, headers: {}, body: nil)
        @client.request(role: role, repository: repo, method: method, path: path, headers: headers, body: body)
      rescue Configuration::Invalid => e
        raise ProviderError, e.message
      end

      def raise_for(response, action)
        return if response.success?
        raise ProviderError, "registry could not #{action} (HTTP #{response.status})"
      end

      def verify_header_digest!(response, digest)
        reported = response.header("docker-content-digest")
        return if reported.nil? || reported == digest
        raise ProviderError, "registry reported digest #{reported} but content hashes to #{digest}"
      end

      def manifest_media_type(manifest)
        JSON.parse(manifest)["mediaType"].presence || MANIFEST_TYPES.first
      rescue JSON::ParserError
        raise ProviderError, "manifest is not valid JSON"
      end

      def manifest_accept = { "Accept" => MANIFEST_TYPES.join(", ") }
      def repository(namespace) = @layout.repository_for(namespace)
      def locator(namespace, digest) = @layout.locator_for(namespace, host: configuration.host, digest: digest)
      def sha256(bytes) = "sha256:#{Digest::SHA256.hexdigest(bytes)}"
    end
  end
end
