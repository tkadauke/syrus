require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe Ios::Ecosystem do
  subject { described_class }

  it_behaves_like "a valid ecosystem provider",
    plugin: "ios", provider: "Ios::Ecosystem",
    contexts: -> { { detect_prepare: Syrus::Plugin::Context::RepoContext.new(repo_path: Rails.root.to_s) } },
    decline_contexts: -> { { detect_prepare: Syrus::Plugin::Context::RepoContext.new(repo_path: nil) } }
end

RSpec.describe Ios::XcodebuildEcosystem do
  subject { described_class }

  it_behaves_like "a valid ecosystem provider",
    plugin: "ios", provider: "Ios::XcodebuildEcosystem",
    contexts: -> { { grader_types: Syrus::Plugin::Context::GraderContext.new(config: valid_config, default_failures: "fail") } },
    decline_contexts: -> { { grader_types: Syrus::Plugin::Context::GraderContext.new } }

  def valid_config
    { "project" => "App.xcodeproj", "scheme" => "App" }
  end
end

RSpec.describe Ios::SwiftpmEcosystem do
  subject { described_class }

  it_behaves_like "a valid ecosystem provider",
    plugin: "ios", provider: "Ios::SwiftpmEcosystem",
    contexts: -> { { grader_types: Syrus::Plugin::Context::GraderContext.new(config: {}, default_failures: "fail") } },
    decline_contexts: -> { { grader_types: Syrus::Plugin::Context::GraderContext.new } }
end
