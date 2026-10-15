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

  let(:output_path) { Rails.application.config.assets.output_path }

  before do
    Rake::Task["assets:precompile"].reenable
    Rake::Task["assets:verify_spa"].reenable
    Rake::Task["assets:precompress"].reenable
    allow(Rails.env).to receive(:development?).and_return(false)
    allow(Syrus::ViteEntrypoint).to receive(:current).and_return("spa-entry-AbC_12-x.digested.js")
  end

  # Stands in for Propshaft writing the compiled build into public/assets.
  def publish(files)
    processor = instance_double(Propshaft::Processor)
    allow(Rails.application.assets).to receive(:processor).and_return(processor)
    allow(processor).to receive(:process) do
      output_path.mkpath
      files.each { |name, content| output_path.join(name).write(content) }
    end
  end

  it "creates a compressed variant for the content-hashed SPA entry after the production asset build" do
    publish(
      "spa-entry-AbC_12-x.digested.js" => %(import "./spa-Search-Zz9_ab-c.digested.js";),
      "spa-Search-Zz9_ab-c.digested.js" => %(import {a} from "./spa-entry-AbC_12-x.digested.js";)
    )

    Rake::Task["assets:precompile"].invoke

    expect(output_path.join("spa-entry-AbC_12-x.digested.js.gz")).to exist
    expect(output_path.join("spa-entry-AbC_12-x.digested.js.br")).to exist
  end

  # Regression: Vite named the entry `spa.digested.js`, which Propshaft does
  # not treat as pre-digested, so it was published as
  # `spa.digested-<sha>.js`. Every lazy chunk importing `./spa.digested.js`
  # then received the HTML app shell instead of JavaScript, and the image
  # still built and deployed.
  it "fails the build when a published chunk imports a file that was not published under that name" do
    publish(
      "spa-entry-AbC_12-x.digested.js" => %(console.log("entry");),
      "spa-Search-Zz9_ab-c.digested.js" => %(import {a} from "./spa.digested.js";)
    )

    expect { Rake::Task["assets:precompile"].invoke }
      .to raise_error(Syrus::SpaBuildVerifier::BrokenReferences, %r{spa-Search-Zz9_ab-c\.digested\.js -> \./spa\.digested\.js})
  end

  it "fails the build when the manifest's entry was not published" do
    publish("spa-Search-Zz9_ab-c.digested.js" => %(console.log("chunk");))

    expect { Rake::Task["assets:precompile"].invoke }
      .to raise_error(Syrus::SpaBuildVerifier::BrokenReferences, /spa-entry-AbC_12-x\.digested\.js was not published/)
  end

  # Regression: `load_tasks` re-evaluates every .rake file and
  # `Rake::Task#enhance` appends an action instead of replacing one, so a
  # process that loaded the task graph twice carried the precompile hook twice
  # and ran it twice for one precompile. Several specs load the graph from
  # `before(:all)`, which left this file passing or failing on example
  # ordering alone -- and it gates a required grader.
  it "verifies the SPA bundle once even after the task graph is loaded again" do
    publish("spa-entry-AbC_12-x.digested.js" => %(console.log("entry");))
    allow(Syrus::SpaBuildVerifier).to receive(:new).and_call_original

    Rails.application.load_tasks
    Rake::Task["assets:precompile"].reenable
    Rake::Task["assets:verify_spa"].reenable
    Rake::Task["assets:precompress"].reenable

    Rake::Task["assets:precompile"].invoke

    expect(Syrus::SpaBuildVerifier).to have_received(:new).once
  end
end
