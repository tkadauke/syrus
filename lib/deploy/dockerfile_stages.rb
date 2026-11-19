# frozen_string_literal: true

require "digest"

module Deploy
  # Reads a multi-stage Dockerfile and digests the text a target stage is
  # built from: the global ARGs before the first FROM, the target, and every
  # stage it reaches through `FROM <stage>` or `COPY --from=<stage>`. Stages it
  # never reaches -- the app code stages, say -- do not change the digest.
  #
  # The digest names a prebuilt image of that stage. As long as the text is
  # unchanged, the image is reused instead of rebuilt, so a deploy never pays
  # for the heavy toolchain layers again just because the local BuildKit cache
  # was pruned to free disk, and every node keeps the layers it already pulled.
  # It deliberately ignores upstream base-image tag movement: the stable,
  # already-pulled image is the point. Bump a version ARG, or set
  # SYRUS_WORKER_DEPS_REFRESH=1, to take newer upstream packages.
  class DockerfileStages
    Stage = Struct.new(:name, :from, :lines)

    def initialize(text)
      @preamble = []
      @stages = []
      parse(text)
    end

    def self.from_file(path) = new(File.read(path))

    def stage_names = @stages.map(&:name).compact

    # The stages +target+ is built from, itself included, in file order.
    def closure(target)
      by_name = @stages.select(&:name).to_h { |stage| [ stage.name, stage ] }
      raise ArgumentError, "unknown Dockerfile stage #{target.inspect}" unless by_name.key?(target)

      needed = {}
      pending = [ target ]
      until pending.empty?
        name = pending.shift
        next if needed.key?(name)

        stage = by_name.fetch(name)
        needed[name] = true
        pending.concat(dependencies(stage).select { |dependency| by_name.key?(dependency) })
      end
      @stages.select { |stage| needed.key?(stage.name) }
    end

    def digest(target)
      text = (@preamble + closure(target).flat_map(&:lines)).join("\n")
      Digest::SHA256.hexdigest(text)[0, 16]
    end

    private

    # Substitutes the defaults of global ARGs (`FROM ${WORKER_DEPS_IMAGE}`),
    # so a stage selected by a build argument is followed like any other.
    def resolve_args(reference)
      defaults = @preamble.filter_map { |line| line.match(/\AARG\s+([A-Za-z_][A-Za-z0-9_]*)=(\S+)/)&.captures }.to_h
      reference.gsub(/\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/) { defaults.fetch(Regexp.last_match(1), Regexp.last_match(0)) }
    end

    def dependencies(stage)
      copies = stage.lines.flat_map { |line| line.scan(/--from=([A-Za-z0-9_.-]+)/).flatten }
      [ stage.from, *copies ].compact.uniq
    end

    def parse(text)
      current = nil
      logical_lines(text).each do |line|
        if (match = line.match(/\AFROM\s+(?:--\S+\s+)*(\S+)(?:\s+AS\s+(\S+))?/i))
          current = Stage.new(match[2], resolve_args(match[1]), [ line ])
          @stages << current
        elsif current
          current.lines << line
        else
          @preamble << line
        end
      end
    end

    # Joins backslash continuations and drops blank lines and comments, so
    # rewording a comment does not force a multi-gigabyte rebuild. Heredoc
    # bodies are kept verbatim: they are content.
    def logical_lines(text)
      lines = []
      buffer = +""
      heredoc = nil
      text.each_line(chomp: true) do |raw|
        if heredoc
          lines << raw
          heredoc = nil if raw.strip == heredoc
          next
        end
        # Docker drops comment lines even inside a continued instruction.
        next if raw.strip.empty? || raw.lstrip.start_with?("#")

        buffer << raw.sub(/\\\s*\z/, "").rstrip << " "
        next if raw.rstrip.end_with?("\\")

        line = buffer.strip.squeeze(" ")
        buffer = +""
        lines << line
        heredoc = line[/<<-?['"]?([A-Za-z_]+)['"]?/, 1]
      end
      lines << buffer.strip unless buffer.strip.empty?
      lines
    end
  end
end
