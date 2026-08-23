require "rails_helper"

RSpec.describe WorkspaceTabsPayload do
  # Bundled plugins (including agent providers Factories.user/repository
  # depend on) are re-registered by the global spec/support/bundled_plugins.rb
  # before hook on every example; resetting only *after* this example keeps
  # that in place for the test body while still preventing the workspace_tab
  # providers registered below from leaking into later examples.
  after { Syrus::PluginRegistry.reset! }

  let(:repo) { Factories.repository }
  let(:chat_session) { ChatSession.create!(repository: repo, user: repo.user) }

  # whiteboard_tools is a real bundled plugin (see spec/support/bundled_plugins.rb)
  # whose workspace_tab provider is unconditionally available, so its tab is
  # always present alongside whatever stub providers a given example
  # registers. Filter it out so these examples can assert on the generic
  # WorkspaceTabsPayload behavior (sorting, availability, disabled-exclusion)
  # in isolation.
  def other_tabs(chat_session)
    described_class.new(chat_session).as_json.reject { |tab| tab[:id] == "whiteboard_tools.canvas" }
  end

  def make_provider(id:, label: id.to_s, order: 0, available: true, label_key: nil)
    Class.new do
      include Syrus::Plugin::WorkspaceTab

      define_singleton_method(:workspace_tabs) do
        [ { id: id, label: label, label_key: label_key, component: "plugin/#{id}", order: order } ]
      end

      define_singleton_method(:available_for?) { |_chat_session| available }
    end
  end

  it "returns an empty array when no :workspace_tab providers are registered" do
    expect(other_tabs(chat_session)).to eq([])
  end

  it "resolves a registered provider's tabs into wire-shaped hashes" do
    provider = make_provider(id: "my_plugin.status", label: "Status", label_key: "my_plugin:tab_status")
    Syrus::PluginRegistry.register(name: "wt_plugin", version: "1.0.0", provides: { workspace_tab: provider })

    expect(other_tabs(chat_session)).to eq([
      {
        id: "my_plugin.status",
        label: "Status",
        label_key: "my_plugin:tab_status",
        component: "plugin/my_plugin.status",
        order: 0
      }
    ])
  end

  it "excludes tabs from a provider whose available_for? returns false" do
    provider = make_provider(id: "my_plugin.hidden", available: false)
    Syrus::PluginRegistry.register(name: "hidden_wt_plugin", version: "1.0.0", provides: { workspace_tab: provider })

    expect(other_tabs(chat_session)).to eq([])
  end

  it "sorts resolved tabs by order, then label" do
    later = make_provider(id: "plugin_b.tab", order: 20)
    earlier = make_provider(id: "plugin_a.tab", order: 10)
    Syrus::PluginRegistry.register(name: "later_wt_plugin", version: "1.0.0", provides: { workspace_tab: later })
    Syrus::PluginRegistry.register(name: "earlier_wt_plugin", version: "1.0.0", provides: { workspace_tab: earlier })

    expect(other_tabs(chat_session).map { |tab| tab[:id] }).to eq([ "plugin_a.tab", "plugin_b.tab" ])
  end

  it "excludes tabs from disabled plugins" do
    provider = make_provider(id: "my_plugin.disabled")
    Syrus::PluginRegistry.register(name: "disabled_wt_plugin", version: "1.0.0", provides: { workspace_tab: provider })
    PluginRecord.find_by!(name: "disabled_wt_plugin").update!(enabled: false)

    expect(other_tabs(chat_session)).to eq([])
  end
end
