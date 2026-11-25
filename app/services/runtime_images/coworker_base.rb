require "rubygems/package"
require "zlib"
require "yaml"
require "digest"
require "stringio"

module RuntimeImages
  # The standard Syrus coworker base image: its reproducible build definition
  # (images/coworker-base), the contract it publishes, and the one way it is
  # submitted to the Runtime Image Service build plane.
  #
  # The image is built from a deterministic archive of its build directory, so
  # the same files always produce the same source digest, and it is published
  # and referenced only by the digest the registry verified. Nothing here reads
  # or passes a credential: the build has no registry or provider secret, and
  # the Dockerfile accepts none.
  class CoworkerBase
    DIRECTORY = Rails.root.join("images", "coworker-base").freeze
    SOURCE_KIND = "syrus_base".freeze
    DIGEST_PINNED = /@sha256:[0-9a-f]{64}\z/
    # Fixed so identical content archives to identical bytes.
    ARCHIVE_MTIME = Time.at(0).utc.freeze
    REQUESTER_KIND = "syrus".freeze

    class InvalidDefinition < StandardError; end

    class << self
      def manifest
        @manifest ||= deep_freeze(YAML.safe_load_file(DIRECTORY.join("base.yml")))
      end

      def reload! = @manifest = nil

      def generation = manifest.fetch("generation")
      def runtime_abi = manifest.fetch("runtime_abi")
      def base_image = manifest.fetch("base_image")
      def platforms = manifest.fetch("platforms")
      def provider_keys = manifest.fetch("providers").map { |provider| provider.fetch("key") }
      def user = manifest.fetch("user")
      def writable_paths = manifest.fetch("writable_paths")
      def build_network = manifest.fetch("build_network")
      def publication = manifest.fetch("publication")

      # Source reference recorded on the image: one per generation, so a later
      # generation never reads as a rebuild of an earlier one.
      def source_ref = "#{publication.fetch("source_ref")}/generation-#{generation}"

      # The build recipe. The pinned base image is passed explicitly so moving
      # it changes the recipe digest, never just a default inside the file.
      def recipe
        { "dockerfile" => "Dockerfile", "context" => ".", "build_args" => { "BASE_IMAGE" => base_image } }
      end

      # Deterministic gzip-compressed tar of the build directory.
      def source_archive
        out = StringIO.new("".b)
        gzip = Zlib::GzipWriter.new(out, Zlib::BEST_COMPRESSION)
        gzip.mtime = ARCHIVE_MTIME
        Gem::Package::TarWriter.new(gzip) do |tar|
          files.each do |relative|
            data = File.binread(DIRECTORY.join(relative))
            tar.add_file_simple(relative, executable?(relative) ? 0o755 : 0o644, data.bytesize) do |entry|
              entry.write(data)
            end
          end
        end
        gzip.close
        out.string
      end

      def source_digest(archive = source_archive) = "sha256:#{Digest::SHA256.hexdigest(archive)}"

      def source_capture(archive = source_archive)
        Builds::SourceCapture.capture(
          kind: SOURCE_KIND, ref: source_ref, revision: source_digest(archive), context_path: ".",
          metadata: { "generation" => generation, "runtime_abi" => runtime_abi }
        )
      end

      # Checks the definition is internally consistent and publishable: the
      # base is digest-pinned, every provider is installed and probed, the
      # identity is non-root, and no credential can enter a layer. Returns the
      # list of problems (empty when the definition is sound).
      def validate
        dockerfile = File.read(DIRECTORY.join("Dockerfile"))
        probe = File.read(DIRECTORY.join("syrus-base-probe"))
        problems = []
        problems << "base_image is not pinned by digest" unless base_image.match?(DIGEST_PINNED)
        problems << "Dockerfile BASE_IMAGE default differs from base.yml" unless dockerfile.include?("ARG BASE_IMAGE=#{base_image}\n")
        problems << "user must be non-root" if user.fetch("uid").to_i.zero? || user.fetch("gid").to_i.zero?
        problems << "Dockerfile does not default COWORKER_UID/GID to base.yml" unless
          dockerfile.include?("ARG COWORKER_UID=#{user.fetch("uid")}\n") && dockerfile.include?("ARG COWORKER_GID=#{user.fetch("gid")}\n")
        problems << "Dockerfile does not end as the non-root user" unless dockerfile.match?(/^USER \$\{COWORKER_UID\}:\$\{COWORKER_GID\}$/)
        problems << "Dockerfile providers label differs from base.yml" unless
          dockerfile.include?(%(io.syrus.coworker-base.providers="#{provider_keys.join(",")}"))
        problems << "Dockerfile generation/ABI labels differ from base.yml" unless
          dockerfile.include?(%(io.syrus.coworker-base.generation="#{generation}")) &&
          dockerfile.include?(%(io.syrus.coworker-base.runtime-abi="#{runtime_abi}"))
        manifest.fetch("providers").each do |provider|
          binary = provider.fetch("binary")
          problems << "#{binary} is not probed by syrus-base-probe" unless probe.match?(/\b#{Regexp.escape(binary)}\b/)
        end
        problems.concat(credential_problems(dockerfile))
        problems
      end

      def validate!
        problems = validate
        raise InvalidDefinition, problems.join("; ") if problems.any?
        true
      end

      # Queues a build of the current definition for +platform+ and returns the
      # request, or the live request / already-published image's request for
      # the same source, recipe, and platform (the plane deduplicates).
      def submit(platform: "linux/amd64", requester_ref: "coworker-base", built_images: BuiltImages.new, orchestrator: Builds::Orchestrator.new)
        validate!
        raise InvalidDefinition, "unsupported platform #{platform.inspect}" unless platforms.include?(platform)

        archive = source_archive
        orchestrator.submit(
          namespace: built_images.namespace_for(publication.fetch("owner_kind"), publication.fetch("owner_ref")),
          source: source_capture(archive), recipe: recipe, platform: platform,
          requester_kind: REQUESTER_KIND, requester_ref: requester_ref,
          source_archive: { io: StringIO.new(archive), filename: "coworker-base-#{generation}.tar.gz", content_type: "application/gzip" }
        )
      end

      # The newest pullable published image for +platform+, or nil. Callers run
      # it by its digest; there is no tag to resolve.
      def current_image(platform: "linux/amd64", built_images: BuiltImages.new)
        built_images.find(owner_kind: publication.fetch("owner_kind"), owner_ref: publication.fetch("owner_ref"),
                          source_kind: SOURCE_KIND, source_ref: source_ref, platform: platform)
      end

      # Arguments for running the in-image probe under the confinement real
      # turns get, against an image reference that is pinned by digest.
      def probe_command(reference, engine: "docker")
        raise InvalidDefinition, "probe image must be referenced by digest" unless reference.to_s.match?(/@sha256:[0-9a-f]{64}\z/)

        uid_gid = "#{user.fetch("uid")}:#{user.fetch("gid")}"
        [ engine, "run", "--rm", "--read-only", "--user", uid_gid, "--cap-drop", "ALL",
          "--security-opt", "no-new-privileges", "--network", "none", "--pids-limit", "256",
          "--tmpfs", "/tmp:rw,noexec,nosuid,size=64m", "--tmpfs", "#{user.fetch("home")}:rw,noexec,nosuid,size=64m,uid=#{user.fetch("uid")},gid=#{user.fetch("gid")}",
          "--entrypoint", "/usr/local/bin/syrus-base-probe", reference ]
      end

      private

      # Manifest data is shared process-wide; freeze it so callers cannot mutate it.
      def deep_freeze(value)
        case value
        when Hash then value.each_value { |v| deep_freeze(v) }
        when Array then value.each { |v| deep_freeze(v) }
        end
        value.freeze
      end

      def files
        Dir.children(DIRECTORY).select { |name| File.file?(DIRECTORY.join(name)) }.sort
      end

      def executable?(relative) = File.executable?(DIRECTORY.join(relative))

      # Credentials never enter a layer: no secret-named ARG/ENV, no secret
      # mounts, no copying of auth files, no registry login in the file.
      CREDENTIAL_NAME = /(?:TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|CREDENTIAL|PRIVATE_KEY|AUTH)/i

      def credential_problems(dockerfile)
        problems = []
        dockerfile.each_line.with_index(1) do |line, number|
          code = line.sub(/#.*/, "")
          if code.match?(/^\s*(?:ARG|ENV)\s+\w*#{CREDENTIAL_NAME.source}\w*/i)
            problems << "Dockerfile line #{number} declares a credential-named ARG/ENV"
          end
          problems << "Dockerfile line #{number} mounts a secret" if code.match?(/--mount=type=(?:secret|ssh)/)
          problems << "Dockerfile line #{number} handles registry or provider auth" if code.match?(/docker login|\.npmrc|auth\.json|\.netrc|\.credentials/i)
        end
        problems
      end
    end
  end
end
