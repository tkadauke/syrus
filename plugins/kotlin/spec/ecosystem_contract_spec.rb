require "rails_helper"
require "syrus/plugin/test_kit"
require "tmpdir"

RSpec.describe Kotlin::Ecosystem do
  subject { described_class }

  let(:repo_context) { Syrus::Plugin::Context::RepoContext.new(repo_path: Rails.root.to_s) }
  let(:empty_repo_context) { Syrus::Plugin::Context::RepoContext.new(repo_path: nil) }
  let(:job_context) { Syrus::Plugin::Context::JobContext.new(repository: Object.new, job: nil) }
  let(:empty_job_context) { Syrus::Plugin::Context::JobContext.new(repository: nil, job: nil) }

  it_behaves_like "a valid ecosystem provider",
    plugin: "kotlin", provider: "Kotlin::Ecosystem",
    contexts: -> { { detect_prepare: repo_context, prompt_context: job_context, review_criteria: repo_context } },
    decline_contexts: lambda {
      { detect_prepare: empty_repo_context, prompt_context: empty_job_context, review_criteria: empty_repo_context }
    }

  it "delegates JVM preparation to Java's facet through the capability registry" do
    java_plan = Syrus::Host::EcosystemPreparePlan.new(
      detected: true, commands: [ "./gradlew testClasses" ], version_file: ".java-version",
      span_labels: [ [ /gradle/, "gradle" ] ], label: "Java"
    )
    java_facet = class_double("JavaFacet", detect_prepare: [ java_plan ])
    java_reference = instance_double(Syrus::Plugin::CapabilityProvider, plugin_name: "java")
    allow(java_reference).to receive(:invoke).and_yield(java_facet)
    allow(Syrus::Host::PluginRegistry).to receive(:capability_providers)
      .with(:ecosystem, :detect_prepare).and_return([ java_reference ])

    Dir.mktmpdir("kotlin-ecosystem") do |dir|
      File.write(File.join(dir, "build.gradle.kts"), "plugins { kotlin(\"jvm\") }\n")
      plan = described_class.detect_prepare(Syrus::Plugin::Context::RepoContext.new(repo_path: dir)).first

      expect(plan.commands).to eq([ "./gradlew testClasses" ])
      expect(plan.label).to eq("Kotlin")
    end
  end
end
