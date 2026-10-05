class PlannedExecutionRequestAnalyzer
  Result = Data.define(:requirement, :ambiguous_reason, :warning) do
    def ambiguous? = ambiguous_reason.present?
  end

  def self.call(job:, loaded_config: nil, source: "prompt")
    new(job: job, loaded_config: loaded_config, source: source).call
  end

  def initialize(job:, loaded_config: nil, source: "prompt")
    @job = job
    @loaded_config = loaded_config
    @source = source
  end

  def call
    return Result.new(requirement: nil, ambiguous_reason: ambiguous_reason, warning: metadata_warning) if ambiguous_reason

    requirement =
      if ios_request?
        requirement_for("macOS implementation", capabilities: { "os" => [ "macos" ], "toolchains" => [ "xcode" ] })
      elsif windows_request?
        requirement_for("Windows implementation", capabilities: { "os" => [ "windows" ], "arch" => arch_values })
      elsif linux_request? || backend_request?
        requirement_for(nil, capabilities: { "os" => [ "linux" ], "arch" => arch_values })
      elsif (fact = matching_capability_fact)
        requirement_for(fact.fetch(:label), capabilities: fact.fetch(:capabilities), target_label: fact[:target_label])
      end

    Result.new(requirement: requirement, ambiguous_reason: nil, warning: metadata_warning)
  end

  private

  attr_reader :job, :loaded_config, :source

  def requirement_for(project_label, capabilities:, target_label: nil)
    capabilities = capabilities.compact_blank
    PlannedExecutionRequirement.new(
      project_label: project_label,
      target_label: target_label,
      capabilities: capabilities,
      source: source
    )
  end

  def ambiguous_reason
    return unless (ios_request? && windows_request?) || (ios_request? && linux_request?) || (windows_request? && linux_request?)

    "The request appears to require mutually incompatible primary implementation hosts. Split the work or explicitly select a primary planned execution host."
  end

  # Only what a human actually wrote. A bug report filed from the in-app
  # reporter has a machine-generated section appended to its body carrying the
  # reporter's browser User-Agent, and a User-Agent names the device it came
  # from -- so reports filed from a phone matched #ios_request? and were
  # assigned to a macOS worker. Nothing in the fleet advertises those
  # capabilities, so the work blocked on `no_capable_worker`, which clears only
  # when an operator adds such a worker. Several ordinary frontend bugs were
  # stranded that way, and one of them held its repository's landing slot.
  #
  # The exclusion is deliberately narrow: it drops the generated section, not
  # anything that merely looks like diagnostics. If an operator writes about a
  # platform in their own words, that still counts.
  def text
    @text ||= [ job.issue_title, authored_body ].join("\n").downcase
  end

  # Fenced blocks quote machine output -- a JSON payload, a log excerpt, a
  # stack trace -- rather than stating what the work is. Jobs filed
  # automatically from a captured browser error embed the whole event payload
  # in a ```json fence, and that payload carries the reporter's User-Agent, so
  # excluding only the Environment section missed them entirely: their
  # User-Agent sits thousands of characters earlier in the body.
  FENCED_BLOCK = /^[ \t]*(`{3,}|~{3,})[^\n]*\n.*?^[ \t]*\1[ \t]*$/m
  # A fence that is opened and never closed: drop the remainder rather than
  # analyze a half-quoted blob.
  UNTERMINATED_FENCE = /^[ \t]*(?:`{3,}|~{3,}).*\z/m

  def authored_body
    body = job.issue_body.to_s
    start = body.index(BugReports::ContextFormatter::SECTION_START)
    body = body[0...start] if start
    body.gsub(FENCED_BLOCK, "\n").sub(UNTERMINATED_FENCE, "\n")
  end

  def ios_request?
    text.match?(/\b(ios|iphone|ipad|xcode|xcodebuild|swiftui|uikit|xcworkspace|xcodeproj)\b/)
  end

  def windows_request?
    text.match?(/\b(windows|win32|msbuild|visual studio|powershell|\.net|wpf|winui)\b/)
  end

  def linux_request?
    text.match?(/\b(linux|ubuntu|debian|glibc|systemd)\b/)
  end

  def backend_request?
    text.match?(/\b(backend|server|api|database|migration|rails|controller|model|worker|queue|cron|graphql|rest)\b/)
  end

  def arch_values
    values = []
    values << "arm64" if text.match?(/\b(arm64|aarch64|apple silicon)\b/)
    values << "x64" if text.match?(/\b(x64|x86_64|amd64)\b/)
    values.presence
  end

  def matching_capability_fact
    capability_facts.find do |fact|
      label = fact.fetch(:label).to_s.downcase
      target_label = fact[:target_label].to_s.downcase
      label.present? && text.include?(label) || target_label.present? && text.include?(target_label)
    end
  end

  def capability_facts
    @capability_facts ||= begin
      config = loaded_config&.config
      facts = []
      if config&.project&.capabilities&.to_h.present?
        project = config.project
        facts << {
          label: project.label.presence || project.id.presence || "Repository",
          target_label: TargetGraph.root_label.to_s,
          capabilities: project.capabilities.to_h
        }
      end
      Array(config&.targets).each do |target|
        next unless target.capabilities&.to_h.present?

        facts << {
          label: target.name,
          target_label: TargetGraph::Label.new(package: "", name: target.name).to_s,
          capabilities: target.capabilities.to_h
        }
      end
      Array(config&.grade&.steps).each do |step|
        next unless step.capabilities&.to_h.present?

        facts << {
          label: step.display_name.presence || step.name,
          target_label: TargetGraph::Label.new(package: "", name: "grade/#{step.name}").to_s,
          capabilities: step.capabilities.to_h
        }
      end
      facts
    end
  end

  def metadata_warning
    return if loaded_config&.loaded? && capability_facts.any?

    "Repository capability metadata is missing or unavailable; planned execution was inferred from the request or defaulted."
  end
end
