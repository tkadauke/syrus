require "rails_helper"

RSpec.describe "Syrus::Host filter, smart-folder, search and presentation facades" do
  ALIASED_FILTER_SEARCH = {
    Filters: ::Filters, SmartFolder: ::SmartFolder, SmartFolderNavigation: Admin::SmartFolderNavigation,
    Paginatable: ::Paginatable, FtsQueryParser: ::FtsQueryParser, SearchRecord: ::SearchRecord,
    SearchIndexVersion: ::SearchIndexVersion, SearchIndexWriteLimits: ::SearchIndexWriteLimits,
    SearchDatabaseTasks: ::SyrusSearchDatabaseTasks, ChatMessageSearchIndex: ::ChatMessageSearchIndex,
    OperationalLogSearch: ::OperationalLogSearch, OperationalLogsPayload: Admin::OperationalLogsPayload,
    JobStateSerializer: Admin::JobStateSerializer, TimelineMacroQuery: Timeline::MacroQuery,
    TimelineWorkflowWaterfallQuery: Timeline::WorkflowWaterfallQuery,
    AdversarialReviewProjects: App::AdversarialReviewProjects, JobDiscussionChatResolver: App::JobDiscussionChatResolver,
    AppPresentation: App::Presentation, ProviderAvailability: App::ProviderAvailability,
    ReviewNoteProjects: App::ReviewNoteProjects, RunArtifactsPayload: App::RunArtifactsPayload
  }.freeze

  ALIASED_FILTER_SEARCH.each do |name, core|
    it "aliases Syrus::Host::#{name} to its core value and declares a public contract" do
      expect(Syrus::Host.const_get(name)).to equal(core)
      expect(Syrus::Host.public?("Syrus::Host::#{name}")).to be(true)
    end

    it "only lists members that exist on Syrus::Host::#{name}" do
      api = Syrus::Host.apis.find { |entry| entry.name == "Syrus::Host::#{name}" }
      expect(api.members).not_to be_empty
      api.members.each do |member|
        if member.match?(/\A[A-Z]/)
          expect(core.const_defined?(member)).to be(true), member
        else
          exists = core.respond_to?(member) || core.method_defined?(member) || core.private_method_defined?(member) ||
            (core.const_defined?(:ClassMethods, false) && (core::ClassMethods.method_defined?(member) || core::ClassMethods.private_method_defined?(member)))
          expect(exists).to be_truthy, "#{name}.#{member}"
        end
      end
    end
  end

  it "exposes the filter bar contract's nested vocabulary through Syrus::Host::Filters" do
    expect(Syrus::Host::Filters::Ast::EMPTY).to equal(Filters::Ast::EMPTY)
    expect(Syrus::Host::Filters::QueryParam::PARAM_NAME).to equal(Filters::QueryParam::PARAM_NAME)
    expect(Syrus::Host::Filters::Chips::Base).to equal(Filters::Chips::Base)
    expect(Syrus::Host::Filters::Chips::DateColumn::UNITS).to equal(Filters::Chips::DateColumn::UNITS)
    expect(Syrus::Host::Filters::Chips::Jobs::JobType).to equal(Filters::Chips::Jobs::JobType)
    expect(Syrus::Host.public?("Syrus::Host::Filters::Ast::AndNode")).to be(true)
  end
end
