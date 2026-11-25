require "digest"
require "json"

module RuntimeImages
  module Builds
    # Freezes what a build will consume. A capture names an immutable
    # revision (a full git commit sha or a sha256 content digest), never a
    # branch or tag, plus the context path inside it. Its digest is computed
    # over canonical JSON, so the same capture always hashes the same.
    class SourceCapture
      REVISION_FORMAT = /\A(?:[0-9a-f]{40}|sha256:[0-9a-f]{64})\z/

      attr_reader :kind, :ref, :manifest, :digest

      def self.capture(kind:, ref:, revision:, context_path: ".", metadata: {})
        new(kind: kind, ref: ref, revision: revision, context_path: context_path, metadata: metadata)
      end

      def initialize(kind:, ref:, revision:, context_path:, metadata:)
        raise Rejected.new("source_invalid", "source kind and ref are required") if kind.blank? || ref.blank?
        unless revision.to_s.match?(REVISION_FORMAT)
          raise Rejected.new("source_not_immutable", "source revision must be a full commit sha or sha256 digest")
        end
        if context_path.to_s.start_with?("/") || context_path.to_s.split("/").include?("..")
          raise Rejected.new("source_invalid", "build context must be a relative path inside the source")
        end

        @kind = kind.to_s
        @ref = ref.to_s
        @manifest = { "kind" => @kind, "ref" => @ref, "revision" => revision.to_s,
                      "context_path" => context_path.to_s, "metadata" => Hash(metadata).deep_stringify_keys }
        @digest = "sha256:#{Digest::SHA256.hexdigest(self.class.canonical_json(@manifest))}"
      end

      def self.canonical_json(value)
        JSON.generate(canonicalize(value))
      end

      def self.canonicalize(value)
        case value
        when Hash then value.sort_by { |k, _| k.to_s }.to_h { |k, v| [ k.to_s, canonicalize(v) ] }
        when Array then value.map { |v| canonicalize(v) }
        else value
        end
      end
    end
  end
end
