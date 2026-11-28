module RuntimeImages
  module Builds
    # The base images a Dockerfile builds FROM, and the digests they resolved to.
    module DockerfileBases
      FROM = /\A\s*FROM\s+(?:--\S+\s+)*(?<ref>\S+)(?:\s+AS\s+(?<stage>\S+))?/i
      ARG_LINE = /\A\s*ARG\s+(?<name>[A-Za-z_][A-Za-z0-9_]*)(?:=(?<value>.*))?\s*\z/i
      VARIABLE = /\$(?:\{(?<braced>[A-Za-z_][A-Za-z0-9_]*)(?::?-(?<default>[^}]*))?\}|(?<plain>[A-Za-z_][A-Za-z0-9_]*))/
      PINNED = /@(?<digest>sha256:[0-9a-f]{64})\z/

      module_function

      # FROM references in order, excluding "scratch" and references to an
      # earlier build stage. Never raises on odd input.
      # ARG defaults declared before a FROM (and +build_args+ overrides) are
      # substituted into the reference; a variable that cannot be resolved is
      # left as written.
      def references(text, build_args = {})
        earlier = []
        found = []
        args = {}
        overrides = Hash(build_args).transform_keys(&:to_s)
        text.to_s.each_line do |line|
          line = line.scrub("")
          if (arg = ARG_LINE.match(line))
            value = arg[:value] ? arg[:value].strip.delete_prefix('"').delete_suffix('"') : nil
            args[arg[:name]] = overrides.fetch(arg[:name]) { value } unless args.key?(arg[:name])
            next
          end
          match = FROM.match(line)
          next unless match

          ref = substitute(match[:ref], args)
          found << ref unless ref.casecmp?("scratch") || earlier.include?(ref.downcase)
          earlier << match[:stage].downcase if match[:stage]
        end
        found.uniq
      end

      # The external image the last stage builds FROM, following references to
      # earlier stages; nil for scratch or an unreadable file. The built image
      # descends from this one only: a base an earlier stage used and the final
      # stage merely copies from is not its ancestor (F158).
      def final_reference(text, build_args = {})
        stages = {}
        args = {}
        overrides = Hash(build_args).transform_keys(&:to_s)
        last = nil
        text.to_s.each_line do |line|
          line = line.scrub("")
          if (arg = ARG_LINE.match(line))
            value = arg[:value] ? arg[:value].strip.delete_prefix('"').delete_suffix('"') : nil
            args[arg[:name]] = overrides.fetch(arg[:name]) { value } unless args.key?(arg[:name])
            next
          end
          match = FROM.match(line)
          next unless match

          ref = substitute(match[:ref], args)
          resolved = stages.fetch(ref.downcase, ref)
          stages[match[:stage].downcase] = resolved if match[:stage]
          last = resolved
        end
        last unless last.nil? || last.casecmp?("scratch")
      end

      def substitute(reference, args)
        reference.gsub(VARIABLE) do
          name = $~[:braced] || $~[:plain]
          value = args[name]
          value.nil? || (value.empty? && $~[:default]) ? ($~[:default] || $&) : value
        end
      end

      # A digest pinned in the reference wins; otherwise the digest the builder
      # reports for an image carrying that name; otherwise nil (not resolved).
      # +final+ marks the entry the final stage descends from (final_reference).
      def resolve(references, images, final: nil)
        references.map do |reference|
          pinned = PINNED.match(reference)
          digest = pinned ? pinned[:digest] : listed_digest(reference, images)
          entry = { "reference" => reference.truncate(300), "pinned" => !pinned.nil?, "digest" => digest }.compact
          final.nil? ? entry : entry.merge("final" => reference == final)
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
