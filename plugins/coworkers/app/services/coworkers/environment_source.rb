require "digest"
require "yaml"

# The coworker environment source tree (environment/Dockerfile,
# environment.yml, smoke-test) in the coworker's persistent workspace. It
# seeds missing files, validates the tree and manifest, and captures an
# immutable revision for builds. Files are edited with the ordinary workspace
# file tools; nothing here adds file-specific tools. Every entry point is
# gated by coworker_custom_environments.
class Coworkers::EnvironmentSource
  DIRECTORY = "environment".freeze
  DOCKERFILE = "#{DIRECTORY}/Dockerfile".freeze
  MANIFEST = "#{DIRECTORY}/environment.yml".freeze
  SMOKE_TEST = "#{DIRECTORY}/smoke-test".freeze
  REQUIRED_FILES = [ DOCKERFILE, MANIFEST, SMOKE_TEST ].freeze
  BASE_ARG = "SYRUS_COWORKER_BASE".freeze
  SCHEMA_VERSION = 1
  MAX_FILES = 64
  MAX_BYTES = 512.kilobytes
  MANIFEST_KEYS = %w[schema_version network_classes smoke_test reason resources].freeze
  RESOURCE_KEYS = %w[cpu memory_mb disk_mb timeout_seconds].freeze
  NETWORK_CLASS_FORMAT = /\A[a-z][a-z0-9_-]{0,63}\z/

  DEFAULT_DOCKERFILE = <<~DOCKERFILE.freeze
    ARG #{BASE_ARG}
    FROM ${#{BASE_ARG}}
    # Coworker additions follow.
  DOCKERFILE
  DEFAULT_MANIFEST = <<~YAML.freeze
    schema_version: #{SCHEMA_VERSION}
    network_classes: []
    smoke_test: ./smoke-test
    reason: ""
  YAML
  DEFAULT_SMOKE_TEST = <<~SH.freeze
    #!/bin/sh
    set -eu
    echo "environment ok"
  SH

  class Disabled < StandardError; end
  class Invalid < StandardError
    attr_reader :errors

    def initialize(errors)
      @errors = Array(errors)
      super(@errors.join("; "))
    end
  end

  Result = Struct.new(:revision, :created, keyword_init: true)

  def initialize(coworker, workspace)
    @coworker = coworker
    @workspace = workspace
  end

  # Writes any missing source file with its template; never overwrites.
  # Returns the paths it created.
  def seed!
    ensure_enabled!
    created = []
    {
      DOCKERFILE => DEFAULT_DOCKERFILE,
      MANIFEST => DEFAULT_MANIFEST,
      SMOKE_TEST => DEFAULT_SMOKE_TEST
    }.each do |path, content|
      next if @workspace.exist?(path)

      @workspace.write(path, content)
      created << path
    end
    environment.transition_to!(:draft) if environment.unconfigured?
    created
  rescue Coworkers::Workspace::InvalidPath => e
    raise Invalid, e.message
  end

  # Returns validation errors for the current tree (empty when valid).
  def validate
    ensure_enabled!
    inspect_tree.last
  end

  # Captures the current valid tree as an immutable revision. An unchanged
  # tree returns the latest revision instead of minting a duplicate.
  def snapshot!(created_by: nil)
    ensure_enabled!
    files, errors = inspect_tree
    raise Invalid, errors if errors.any?

    manifest = build_manifest(files)
    digest = "sha256:#{Digest::SHA256.hexdigest(canonical(manifest))}"
    recipe = "sha256:#{Digest::SHA256.hexdigest(files.fetch(DOCKERFILE))}"

    environment.with_lock do
      latest = environment.revisions.last
      next Result.new(revision: latest, created: false) if latest&.source_digest == digest

      revision = environment.revisions.create!(
        number: environment.next_revision_number, source_digest: digest, source_manifest: manifest,
        recipe_digest: recipe, created_by_user: created_by
      )
      environment.transition_to!(:draft) if environment.unconfigured?
      Result.new(revision: revision, created: true)
    end
  end

  private

  def ensure_enabled!
    raise Disabled, "coworker custom environments are not enabled" unless Feature.coworker_custom_environments_enabled?
  end

  def environment
    @environment ||= Coworkers::Environment.find_or_create_by!(coworker_id: @coworker.id)
  end

  def inspect_tree
    files = @workspace.read_tree(DIRECTORY, max_files: MAX_FILES, max_bytes: MAX_BYTES)
    errors = []
    REQUIRED_FILES.each { |path| errors << "#{path} is missing" unless files.key?(path) }
    files.each do |path, content|
      errors << "#{path} must be UTF-8 text" unless utf8_text?(content)
    end
    errors.concat(dockerfile_errors(files[DOCKERFILE])) if files[DOCKERFILE] && utf8_text?(files[DOCKERFILE])
    errors.concat(manifest_errors(files[MANIFEST])) if files[MANIFEST] && utf8_text?(files[MANIFEST])
    [ files, errors ]
  rescue Coworkers::Workspace::InvalidPath => e
    [ {}, [ e.message ] ]
  end

  def utf8_text?(content)
    text = content.dup.force_encoding(Encoding::UTF_8)
    text.valid_encoding? && !text.include?("\0")
  end

  # The effective final stage must descend from the supplied base: either it
  # names the base arg directly or an earlier stage that does.
  def dockerfile_errors(content)
    instructions = dockerfile_instructions(content)
    if instructions.any? { |line| line.match?(/\A(RUN|COPY|ADD)\s/i) && line.include?("\\<") }
      return [ "#{DOCKERFILE} must not escape '<' in RUN, COPY, or ADD; the validator cannot model it" ]
    end

    froms = instructions.filter_map do |line|
      line[/\AFROM\s+(?:--\S+\s+)*(\S+)(?:\s+AS\s+(\S+))?/i, 0] && Regexp.last_match
    end
    return [ "#{DOCKERFILE} must contain a FROM instruction" ] if froms.empty?

    based = []
    froms.each do |match|
      image = match[1]
      descends = image.match?(/\A\$\{?#{BASE_ARG}\}?\z/) || based.include?(image.downcase)
      based << match[2].downcase if descends && match[2]
      @final_descends = descends
    end
    @final_descends ? [] : [ "#{DOCKERFILE} final stage must descend from ${#{BASE_ARG}}" ]
  end

  # Logical Dockerfile instructions: continuation lines are joined and heredoc
  # bodies are dropped so their payload can never read as an instruction.
  def dockerfile_instructions(content)
    raw = content.dup.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
    instructions = []
    until raw.empty?
      line = raw.shift
      next if line.strip.empty? || line.strip.start_with?("#")

      logical = line.rstrip
      while logical.end_with?("\\") && raw.any?
        logical = "#{logical.chomp("\\")} #{raw.shift.strip}"
      end
      instructions << logical.strip
      next unless logical.strip.match?(/\A(RUN|COPY|ADD)\s/i)

      heredoc_openers(logical).each do |dash, tag|
        while raw.any?
          body = raw.shift
          break if (dash == "-" ? body.sub(/\A\t+/, "") : body) == tag
        end
      end
    end
    instructions
  end

  # Heredoc operands (<<TAG, <<-TAG, <<"TAG") found outside quoted strings, so
  # quoted text like `echo "<<CMD"` never swallows the lines that follow it.
  HEREDOC_SCAN = /(?<!<)<<(?!<)(-?)(?:"([\w.-]+)"|'([\w.-]+)'|([\w.-]+))|"(?:[^"\\]|\\.)*"|'[^']*'/
  private_constant :HEREDOC_SCAN

  def heredoc_openers(logical)
    logical.to_enum(:scan, HEREDOC_SCAN).filter_map do
      m = Regexp.last_match
      tag = m[2] || m[3] || m[4]
      [ m[1], tag ] if tag
    end
  end

  def manifest_errors(content)
    data = YAML.safe_load(content.dup.force_encoding(Encoding::UTF_8), permitted_classes: [], aliases: false)
    return [ "#{MANIFEST} must be a mapping" ] unless data.is_a?(Hash)

    errors = []
    unknown = data.keys.map(&:to_s) - MANIFEST_KEYS
    errors << "#{MANIFEST} has unsupported keys: #{unknown.sort.join(', ')}" if unknown.any?
    errors << "#{MANIFEST} schema_version must be #{SCHEMA_VERSION}" unless data["schema_version"] == SCHEMA_VERSION
    classes = data["network_classes"]
    unless classes.is_a?(Array) && classes.all? { |c| c.is_a?(String) && c.match?(NETWORK_CLASS_FORMAT) }
      errors << "#{MANIFEST} network_classes must be a list of class names"
    end
    errors << "#{MANIFEST} smoke_test must be a relative path inside #{DIRECTORY}" unless smoke_test_path_ok?(data["smoke_test"])
    errors << "#{MANIFEST} reason must be a string" if data.key?("reason") && !data["reason"].is_a?(String)
    errors.concat(resource_errors(data["resources"])) if data.key?("resources")
    errors
  rescue Psych::Exception => e
    [ "#{MANIFEST} is not valid YAML: #{e.message.lines.first.to_s.strip}" ]
  end

  def smoke_test_path_ok?(value)
    return false unless value.is_a?(String) && value.present?

    path = Pathname.new(value)
    !path.absolute? && !path.cleanpath.each_filename.include?("..") && path.cleanpath.to_s != "."
  end

  def resource_errors(resources)
    return [ "#{MANIFEST} resources must be a mapping" ] unless resources.is_a?(Hash)

    errors = []
    unknown = resources.keys.map(&:to_s) - RESOURCE_KEYS
    errors << "#{MANIFEST} has unsupported resource keys: #{unknown.sort.join(', ')}" if unknown.any?
    bad = resources.reject { |_, v| v.is_a?(Integer) && v.positive? }.keys
    errors << "#{MANIFEST} resources must be positive integers: #{bad.join(', ')}" if bad.any?
    errors
  end

  # Files are stored inline so the revision stays buildable after the
  # workspace changes; the bytes are bounded by MAX_BYTES.
  def build_manifest(files)
    {
      "schema_version" => SCHEMA_VERSION,
      "files" => files.sort.to_h do |path, content|
        [ path, { "sha256" => Digest::SHA256.hexdigest(content), "size" => content.bytesize,
                  "content" => content.dup.force_encoding(Encoding::UTF_8) } ]
      end
    }
  end

  def canonical(manifest)
    manifest.fetch("files").map { |path, f| "#{path}\0#{f['sha256']}" }.join("\n")
  end
end
