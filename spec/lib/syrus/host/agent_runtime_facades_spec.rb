require "rails_helper"

RSpec.describe "Syrus::Host agent-runtime facades" do
  ALIASED_AGENT_RUNTIME = {
    AgentRecord: ::Agent,
    AgentProviderRegistry: ::AgentProviders,
    AgentProviderBase: ::AgentProviders::Base,
    AgentProviderConfigurationError: ::AgentProviders::ConfigurationError,
    AgentSessionStore: ::AgentProviders::SessionStore,
    ChatProviderBase: ::ChatProviders::Base,
    ChatProviderConfigurationError: ::ChatProviders::ConfigurationError,
    AgentTranscript: ::ClaudeTranscript,
    AgentEventAbbreviator: ::AgentEventAbbreviator,
    AgentSidecarEnvironment: ::AgentSidecarEnvironment,
    ProviderAuthFailure: ::ProviderAuthFailure,
    ProviderUsageLimit: ::ProviderUsageLimit,
    ProviderModelUnsupported: ::ProviderModelUnsupported,
    ProviderAvailabilityEvidence: ::ProviderAvailabilityEvidence,
    ProviderRateLimitEvidence: ::ProviderRateLimitEvidence,
    ProviderQuotaReset: ::ProviderQuotaReset,
    ProviderSession: ::ProviderSession,
    CodexAccountScope: ::CodexAccountScope,
    ValidatesAgentProvider: ::ValidatesAgentProvider,
    RebaseAttemptGuard: ::RebaseAttemptGuard,
    PlatformIdentityRecord: ::PlatformIdentity,
    PlatformConfigBase: ::PlatformIdentity::PlatformConfig::Base,
    AdversarialReviewPrompt: ::Prompts::AdversarialReview,
    ChatProviderOptions: ::ChatProviderOptions,
    AgentProviderCatalogOptions: ::AgentProviderCatalogOptions
  }.freeze

  def api_for(name) = Syrus::Host.apis.find { |entry| entry.name == "Syrus::Host::#{name}" }

  ALIASED_AGENT_RUNTIME.each do |name, core|
    it "aliases Syrus::Host::#{name} to its core value and declares a public contract" do
      expect(Syrus::Host.const_get(name)).to equal(core)
      expect(Syrus::Host.public?("Syrus::Host::#{name}")).to be(true)
    end

    it "only lists members that exist on Syrus::Host::#{name}" do
      api_for(name).members.each do |member|
        exists = if member.match?(/\A[A-Z]/)
          core.const_defined?(member)
        else
          core.respond_to?(member) || core.method_defined?(member) || core.private_method_defined?(member) ||
            (core.respond_to?(:column_names) && core.column_names.any?)
        end
        expect(exists).to be_truthy, "#{name}.#{member}"
      end
    end
  end

  it "lists every agent role the plugins use and keeps them identical to core" do
    members = api_for(:AgentRole).members
    expect(members).to include("CHAT_PLANNER", "CHAT_CODING", "CHAT_LOCAL", "CHAT_ROLES", "WORKFLOW_IMPLEMENT",
      "WORKFLOW_ADVERSARIAL_REVIEWER", "WORKFLOW_VISUAL_REVIEWER", "WORKFLOW_ROLES", "AGENT_INSIGHT")
    members.each { |role| expect(Syrus::Host::AgentRole.const_get(role)).to equal(AgentRole.const_get(role)) }
  end

  it "keeps the provider outcome classes' outcomes available through the facade" do
    expect(Syrus::Host::ProviderUsageLimit::OUTCOME).to eq("provider_usage_limit")
    expect(Syrus::Host::ProviderAuthFailure::OUTCOME).to eq(ProviderAuthFailure::OUTCOME)
    expect(Syrus::Host::ProviderModelUnsupported::OUTCOME).to eq(ProviderModelUnsupported::OUTCOME)
  end

  describe Syrus::Host::AgentRuntime do
    it "exposes the chat workload policy for the current setting" do
      policy = instance_double(Execution::ChatWorkloadPolicy)
      allow(Execution::ChatWorkloadPolicy).to receive(:for_current_setting).and_return(policy)

      expect(described_class.chat_workload_policy).to equal(policy)
    end
  end

  describe Syrus::Host::AgentPrompts do
    it "delegates memory context to the core prompt and returns a string" do
      user = instance_double(User)
      context = instance_double(Prompts::MemoryContext, to_s: "remembered")
      allow(Prompts::MemoryContext).to receive(:new).with(user:, repository_ids: [ 1 ]).and_return(context)

      expect(described_class.memory_context(user:, repository_ids: [ 1 ])).to eq("remembered")
    end

    it "delegates the chat system prompt" do
      prompt = instance_double(Prompts::ChatSystem, to_s: "system")
      allow(Prompts::ChatSystem).to receive(:new).with(repository: :repo, chat_session: :chat).and_return(prompt)

      expect(described_class.chat_system(repository: :repo, chat_session: :chat)).to eq("system")
    end

    it "returns the shared safety and summary instructions" do
      expect(described_class.git_safety_text).to equal(Prompts::GitSafety::TEXT)
      expect(described_class.submit_summary_instructions_text).to equal(Prompts::SubmitSummaryInstructions::TEXT)
    end
  end

  describe Syrus::Host::SkillCatalog do
    it "exposes the skill name pattern" do
      expect(described_class.name_pattern).to equal(Skills::NAME_PATTERN)
    end

    it "resolves, validates and renders through the core skill loader" do
      parameters = [ :param ]
      definition = instance_double(Skills::Definition, parameters:) if defined?(Skills::Definition)
      definition ||= double("definition", parameters:)
      resolution = double("resolution", definition:)
      allow(Skills).to receive(:for).with(repository: :repo, name: "demo", user: :user).and_return(resolution)
      allow(Skills::ParameterSchema).to receive(:validate!)
      allow(Skills::Renderer).to receive(:render).with(definition, { "a" => 1 }).and_return("body")

      expect(described_class.resolve(repository: :repo, name: "demo", user: :user)).to equal(resolution)
      described_class.validate_arguments!(resolution, { "a" => 1 })
      expect(Skills::ParameterSchema).to have_received(:validate!).with(parameters, { "a" => 1 })
      expect(described_class.render(resolution, { "a" => 1 })).to eq("body")
    end

    it "names the resolution and argument errors callers rescue" do
      expect(described_class.resolution_errors).to contain_exactly(
        Skills::NotFoundError, ArgumentError, Skills::SkillMarkdown::ParseError, Skills::ParameterSchema::ParseError
      )
      expect(described_class.argument_errors).to eq([ Skills::ParameterSchema::ValidationError ])
    end
  end
end
