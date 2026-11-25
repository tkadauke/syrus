module RuntimeImages
  module Builds
    # The base images a Dockerfile builds FROM, and the digests they resolved to.
    module DockerfileBases
      FROM = /\A\s*FROM\s+(?:--\S+\s+)*(?<ref>\S+)(?:\s+AS\s+(?<stage>\S+))?/i
      PINNED = /@(?<digest>sha256:[0-9a-f]{64})\z/

      module_function

      # FROM references in order, excluding "scratch" and references to an
      # earlier build stage. Never raises on odd input.
      def references(text)
        earlier = []
        found = []
        text.to_s.each_line do |line|
          match = FROM.match(line.scrub(""))
          next unless match

          ref = match[:ref]
          found << ref unless ref.casecmp?("scratch") || earlier.include?(ref.downcase)
          earlier << match[:stage].downcase if match[:stage]
        end
        found.uniq
      end

      # A digest pinned in the reference wins; otherwise the digest the builder
      # reports for an image carrying that name; otherwise nil (not resolved).
      def resolve(references, images)
        references.map do |reference|
          pinned = PINNED.match(reference)
          digest = pinned ? pinned[:digest] : listed_digest(reference, images)
          { "reference" => reference.truncate(300), "pinned" => !pinned.nil?, "digest" => digest }.compact
        end
      end

      def listed_digest(reference, images)
        wanted = normalize(reference)
        Array(images).each do |image|
          next unless image.is_a?(Hash)

          names = Array(image["names"]).map { |name| normalize(name) }
          return image["digest"] if image["digest"].to_s.match?(/\Asha256:[0-9a-f]{64}\z/) && names.include?(wanted)
        end
        nil
      end

      def normalize(name)
        value = name.to_s.sub(/@sha256:.*\z/, "").sub(%r{\A(docker\.io|index\.docker\.io|registry-1\.docker\.io)/}, "")
        value = value.delete_prefix("library/")
        value.match?(/:[^\/]+\z/) ? value : "#{value}:latest"
      end
    end
  end
end
