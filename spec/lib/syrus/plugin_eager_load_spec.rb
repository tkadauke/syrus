require "rails_helper"

# Ruby cannot unload a constant tree, so a disabled plugin can only be kept
# *out* of the load, never taken back out of it. Skipping eager load is that,
# and it stays autoloadable so enabling needs no restart.
RSpec.describe Syrus::PluginEagerLoad do
  let(:loader) { instance_double(Zeitwerk::Loader) }
  let(:root) { Pathname.new("/app") }

  def dirs(*paths)
    allow(loader).to receive(:dirs).and_return(paths)
    allow(loader).to receive(:do_not_eager_load)
  end

  it "excludes every directory under a disabled plugin" do
    dirs("/app/plugins/terminal/app/models", "/app/plugins/terminal/app/services", "/app/app/models")

    excluded = described_class.apply!(loader: loader, root: root, names: [ "terminal" ])

    expect(excluded).to contain_exactly("/app/plugins/terminal/app/models", "/app/plugins/terminal/app/services")
    expect(loader).to have_received(:do_not_eager_load).twice
  end

  it "leaves core and enabled plugins alone" do
    dirs("/app/app/models", "/app/plugins/mockups/app/services")

    expect(described_class.apply!(loader: loader, root: root, names: [ "terminal" ])).to be_empty
    expect(loader).not_to have_received(:do_not_eager_load)
  end

  # A plugin named as a prefix of another must not drag it along.
  it "does not match a plugin whose name merely prefixes the directory" do
    dirs("/app/plugins/terminal_extras/app/models")

    expect(described_class.apply!(loader: loader, root: root, names: [ "terminal" ])).to be_empty
  end

  it "does nothing when every plugin is enabled" do
    allow(loader).to receive(:dirs)

    expect(described_class.apply!(loader: loader, root: root, names: [])).to eq([])
    expect(loader).not_to have_received(:dirs)
  end

  # Withholding code because a database lookup failed would turn an unavailable
  # database into missing behaviour.
  it "eager loads everything when the enabled set cannot be read" do
    # The read that actually fails on a fresh or broken database.
    allow(Syrus::PluginRegistry).to receive(:plugin_records_by_name).and_raise(ActiveRecord::StatementInvalid.new("no such table"))

    expect(Syrus::PluginRegistry.eager_load_skippable_plugin_names).to eq([])
  end
end
