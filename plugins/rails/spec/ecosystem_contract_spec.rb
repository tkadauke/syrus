require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe SyrusRails::Ecosystem do
  subject { described_class }

  it_behaves_like "a valid ecosystem provider",
    plugin: "syrus-rails", provider: "SyrusRails::Ecosystem",
    contexts: lambda {
      { prompt_context: Syrus::Plugin::Context::JobContext.new(repository: Object.new, job: nil) }
    },
    decline_contexts: lambda {
      { prompt_context: Syrus::Plugin::Context::JobContext.new(repository: nil, job: nil) }
    }
end
