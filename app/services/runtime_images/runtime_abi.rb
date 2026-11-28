require "yaml"
require "json"
require "digest"
require "openssl"

module RuntimeImages
  # The versioned runtime ABI between Syrus and coworker images: the contract
  # (images/coworker-base/abi.yml), the OCI labels that carry it, the signed
  # provenance attestation that binds it to one build, and the pre-launch
  # check that refuses an incompatible or unattested image.
  #
  # Nothing here starts a container or falls back to host execution. A failed
  # check is a typed refusal the launcher turns into a blocked state.
  class RuntimeAbi
    PATH = CoworkerBase::DIRECTORY.join("abi.yml").freeze
    LABEL_PREFIX = "io.syrus.runtime-abi".freeze
    ATTESTATION_KEY = "runtime_abi_attestation".freeze
    SIGNATURE_ALGORITHM = "HMAC-SHA256".freeze
    SIGNING_PURPOSE = "runtime-abi-provenance".freeze
    # The confinement policy version this Syrus build enforces.
    CONFINEMENT_POLICY_VERSION = 1

    # +code+ is machine-readable (stable); +message+ is for operators.
    Problem = Data.define(:code, :message)

    class Result
      attr_reader :problems

      def initialize(problems) = @problems = problems.freeze
      def compatible? = problems.empty?
      def codes = problems.map(&:code)
      def messages = problems.map(&:message)
    end

    class Incompatible < StandardError
      attr_reader :result

      def initialize(result)
        @result = result
        super("runtime ABI incompatible: #{result.messages.join("; ")}")
      end
    end

    class << self
      def contract = @contract ||= deep_freeze(YAML.safe_load_file(PATH))
      def reload! = @contract = nil

      def version = contract.fetch("version")
      def compatibility = contract.fetch("compatibility")
      def min_confinement_policy = contract.fetch("min_confinement_policy")
      def providers = contract.fetch("providers")
      def effective_compatibility
        policy = EnvironmentPolicy.current
        { "min" => policy.fetch("base", "supported_abi_min"), "max" => policy.fetch("base", "supported_abi_max") }
      end

      def supported?(abi_version)
        range = effective_compatibility
        abi_version.is_a?(Integer) && abi_version.between?(range.fetch("min"), range.fetch("max"))
      end

      # Canonical JSON (sorted keys) so the digest never depends on YAML order.
      def canonical(value = contract) = JSON.generate(sort_keys(value))
      def digest = "sha256:#{Digest::SHA256.hexdigest(canonical)}"

      # OCI labels for the Dockerfile. A spec asserts the Dockerfile carries
      # exactly these, so the labels cannot drift from the contract.
      def labels
        {
          "#{LABEL_PREFIX}.version" => version.to_s,
          "#{LABEL_PREFIX}.compat-min" => compatibility.fetch("min").to_s,
          "#{LABEL_PREFIX}.compat-max" => compatibility.fetch("max").to_s,
          "#{LABEL_PREFIX}.min-confinement-policy" => min_confinement_policy.to_s,
          "#{LABEL_PREFIX}.contract-digest" => digest
        }
      end

      # Internal consistency of the definition. Returns problems (empty = sound).
      def validate_definition
        problems = []
        problems << "abi.version #{version} differs from base.yml runtime_abi #{CoworkerBase.runtime_abi}" unless version == CoworkerBase.runtime_abi
        problems << "abi.version #{version} is outside its own compatibility range" unless version.between?(compatibility.fetch("min"), compatibility.fetch("max"))
        problems << "providers differ from base.yml" unless providers.keys.sort == CoworkerBase.provider_keys.sort
        problems << "user differs from base.yml" unless contract.fetch("user").slice("name", "uid", "gid") == CoworkerBase.user.to_h.slice("name", "uid", "gid")
        problems << "provider home differs from base.yml" unless contract.dig("filesystem", "provider_home") == CoworkerBase.user.to_h["home"]
        problems << "root user must be forbidden" unless contract.dig("user", "root") == "forbidden"
        problems << "filesystem root must be read_only" unless contract.dig("filesystem", "root") == "read_only"
        problems << "scratch must be optional and admin-enabled" unless contract.dig("filesystem", "scratch").values_at("required", "availability") == [ false, "admin_enabled" ]
        problems << "tmp must be nosuid,nodev,noexec" unless (%w[nosuid nodev noexec] - contract.dig("filesystem", "tmp", "options")).empty?
        problems << "declared volumes must be forbidden" unless contract.dig("filesystem", "declared_volumes") == "forbidden"
        problems << "mcp socket paths disagree" unless contract.dig("mcp", "socket") == contract.dig("filesystem", "mcp_socket", "path")
        problems << "provider paths must be absolute" unless providers.values.all? { |p| p.fetch("path").start_with?("/") }
        problems << "min_confinement_policy exceeds what this Syrus enforces" if min_confinement_policy > CONFINEMENT_POLICY_VERSION
        problems
      end

      # Signed attestation for one build. It binds the contract to the build's
      # source and recipe digests, so a contract (or image) cannot be swapped
      # under an existing signature. Stored on the image's provenance.
      def attest(source_digest:, recipe_digest:, build_request_id: nil)
        payload = attestation_payload(source_digest: source_digest, recipe_digest: recipe_digest, build_request_id: build_request_id)
        { "payload" => payload, "algorithm" => SIGNATURE_ALGORITHM, "signature" => sign(payload) }
      end

      def attestation_valid?(attestation, source_digest:, recipe_digest:)
        return false unless attestation.is_a?(Hash) && attestation["payload"].is_a?(Hash) && attestation["signature"].is_a?(String)
        return false unless attestation["algorithm"] == SIGNATURE_ALGORITHM

        payload = attestation["payload"]
        return false unless payload["source_digest"] == source_digest && payload["recipe_digest"] == recipe_digest

        ActiveSupport::SecurityUtils.secure_compare(attestation["signature"], sign(payload))
      end

      # Pre-launch validation. +labels+ are the image's OCI labels as inspected
      # from the pulled-by-digest image, +image+ the RuntimeImage record.
      # +provider+ is the provider key the turn will run; +confinement_policy+
      # is the version the worker backend verified it enforces.
      # A nil +provider+ skips the provider check (cache warm-up paths that
      # do not yet know which provider will run).
      def validate_for_launch(image:, labels:, provider:, confinement_policy: CONFINEMENT_POLICY_VERSION)
        problems = []
        add = ->(code, message) { problems << Problem.new(code: code, message: message) }
        labels = labels.to_h.transform_keys(&:to_s)

        unless image.availability == "available" && image.revoked_at.nil?
          add.call("image_not_launchable", "image #{image.digest} is #{image.availability}")
        end

        image_version = Integer(labels["#{LABEL_PREFIX}.version"], 10, exception: false)
        if image_version.nil?
          add.call("abi_missing", "image does not declare #{LABEL_PREFIX}.version")
        else
          range = [ Integer(labels["#{LABEL_PREFIX}.compat-min"], 10, exception: false), Integer(labels["#{LABEL_PREFIX}.compat-max"], 10, exception: false) ]
          add.call("abi_range_invalid", "image compatibility range is missing or malformed") if range.any?(&:nil?)
          effective = effective_compatibility
          add.call("abi_unsupported", "image ABI #{image_version} is outside the supported range #{effective.fetch("min")}..#{effective.fetch("max")}") unless supported?(image_version)
          if range.none?(&:nil?) && !version.between?(*range)
            add.call("abi_range_excludes_syrus", "image supports ABI #{range.join("..")}, this Syrus speaks #{version}")
          end
        end

        required_policy = Integer(labels["#{LABEL_PREFIX}.min-confinement-policy"], 10, exception: false)
        if required_policy.nil?
          add.call("confinement_policy_missing", "image does not declare a minimum confinement policy")
        elsif required_policy > confinement_policy
          add.call("confinement_policy_too_old", "image requires confinement policy #{required_policy}; worker enforces #{confinement_policy}")
        end

        add.call("provider_unsupported", "provider #{provider.inspect} is not provided by ABI #{version}") unless provider.nil? || providers.key?(provider.to_s)

        verify_provenance(image, labels, add)
        Result.new(problems)
      end

      def validate_for_launch!(**args)
        result = validate_for_launch(**args)
        raise Incompatible, result unless result.compatible?
        result
      end

      # Admission can reject a stale provider/ABI contract before a worker
      # pulls the image. The worker still performs the complete label and
      # confinement validation against the pulled image immediately before
      # launch.
      def current_contract?(image, provider: nil)
        return false unless provider.nil? || providers.key?(provider.to_s)

        attestation = Hash(image.provenance)[ATTESTATION_KEY]
        recipe_digest = Hash(image.provenance)["recipe_digest"]
        attestation_valid?(attestation, source_digest: image.source_digest, recipe_digest:) &&
          attestation.dig("payload", "contract_digest") == digest
      end

      def outdated_contract?(image)
        attestation = Hash(image.provenance)[ATTESTATION_KEY]
        recipe_digest = Hash(image.provenance)["recipe_digest"]
        attestation_valid?(attestation, source_digest: image.source_digest, recipe_digest:) &&
          attestation.dig("payload", "contract_digest") != digest
      end

      private

      def verify_provenance(image, labels, add)
        attestation = Hash(image.provenance)[ATTESTATION_KEY]
        recipe_digest = Hash(image.provenance)["recipe_digest"]
        unless attestation_valid?(attestation, source_digest: image.source_digest, recipe_digest: recipe_digest)
          add.call("provenance_unsigned", "image provenance has no valid runtime ABI signature")
          return
        end
        signed = attestation.fetch("payload")
        add.call("contract_mismatch", "image labels do not match the signed contract") unless labels["#{LABEL_PREFIX}.contract-digest"] == signed["contract_digest"]
        add.call("contract_outdated", "image runtime contract differs from the current provider and ABI contract") unless signed["contract_digest"] == digest
        # Every label the launch decision trusts must equal what Syrus signed,
        # so a builder cannot widen the range or lower the confinement floor.
        { "version" => "version", "compat-min" => "compat_min", "compat-max" => "compat_max", "min-confinement-policy" => "min_confinement_policy" }.each do |label, key|
          next if labels["#{LABEL_PREFIX}.#{label}"].to_s == signed[key].to_s
          add.call("label_mismatch", "image label #{LABEL_PREFIX}.#{label} differs from the signed contract (#{key})")
        end
      end

      def attestation_payload(source_digest:, recipe_digest:, build_request_id:)
        { "version" => version, "compat_min" => compatibility.fetch("min"), "compat_max" => compatibility.fetch("max"),
          "min_confinement_policy" => min_confinement_policy, "contract_digest" => digest, "generation" => CoworkerBase.generation,
          "source_digest" => source_digest, "recipe_digest" => recipe_digest, "build_request_id" => build_request_id }.compact
      end

      def sign(payload)
        OpenSSL::HMAC.hexdigest("SHA256", signing_key, canonical(payload))
      end

      def signing_key = Rails.application.key_generator.generate_key(SIGNING_PURPOSE, 32)

      def sort_keys(value)
        case value
        when Hash then value.sort_by { |k, _| k.to_s }.to_h { |k, v| [ k.to_s, sort_keys(v) ] }
        when Array then value.map { |v| sort_keys(v) }
        else value
        end
      end

      def deep_freeze(value)
        case value
        when Hash then value.each_value { |v| deep_freeze(v) }
        when Array then value.each { |v| deep_freeze(v) }
        end
        value.freeze
      end
    end
  end
end
