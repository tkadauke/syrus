require "rails_helper"
require "rake"
require "tmpdir"

RSpec.describe "assets:precompile" do
  before(:all) do
    Rails.application.load_tasks
  end

  around do |example|
    Dir.mktmpdir("precompressed-assets") do |dir|
      original_output_path = Rails.application.config.assets.output_path
      Rails.application.config.assets.output_path = Pathname.new(dir)
      example.run
    ensure
      Rails.application.config.assets.output_path = original_output_path
    end
  end

  before do
    Rake::Task["assets:precompile"].reenable
    Rake::Task["assets:precompress"].reenable
    allow(Rails.env).to receive(:development?).and_return(false)
    allow(Syrus::SpaEntrypointPublisher).to receive(:new).and_return(
      instance_double(Syrus::SpaEntrypointPublisher, call: Rails.application.config.assets.output_path.join("spa.js"))
    )
  end

  it "creates a compressed variant for the fingerprinted SPA entry bundle after the production asset build" do
    output_path = Rails.application.config.assets.output_path
    processor = instance_double(Propshaft::Processor)
    allow(Rails.application.assets).to receive(:processor).and_return(processor)
    allow(processor).to receive(:process) do
      output_path.mkpath
      output_path.join("spa-entry-abc123.js").write("console.log('entry bundle');")
    end

    Rake::Task["assets:precompile"].invoke

    expect(Syrus::SpaEntrypointPublisher).to have_received(:new).with(
      source_path: Rails.root.join("app/assets/builds/spa.digested.js"),
      output_path: output_path
    )
    expect(output_path.join("spa-entry-abc123.js.gz")).to exist
    expect(output_path.join("spa-entry-abc123.js.br")).to exist
  end
end
