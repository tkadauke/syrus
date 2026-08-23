require "rails_helper"

RSpec.describe "plugin workspace tab contracts" do
  it "declares installed workspace tabs with frontend and i18n metadata" do
    manifests = Syrus::PluginRegistry.all_plugins
    workspace_tab_manifests = manifests.select { |manifest| manifest.provides.key?(:workspace_tab) }

    expect(workspace_tab_manifests).not_to be_empty

    workspace_tab_manifests.each do |manifest|
      metadata = manifest.metadata.with_indifferent_access
      frontend_workspace_tabs = metadata.dig(:frontend, :workspace_tabs).to_h
      i18n_patterns = Array(metadata.dig(:frontend, :i18n))

      Array(manifest.provides[:workspace_tab]).each do |provider|
        Array(provider.workspace_tabs).each do |raw_tab|
          tab = raw_tab.to_h.symbolize_keys

          expect(tab[:id].to_s).to start_with("#{manifest.name}.")
          expect(tab[:label_key]).to be_present
          expect(tab[:component]).to be_present
          expect(frontend_workspace_tabs.keys).to include(tab[:component])

          namespace, key = tab[:label_key].to_s.split(":", 2)
          expect(namespace).to be_present
          expect(key).to be_present
          matching_locale_files = i18n_patterns.flat_map do |pattern|
            Dir[Rails.root.join("plugins", manifest.name, pattern).to_s]
          end
          expect(matching_locale_files).not_to be_empty
          expect(matching_locale_files).to all(include("/#{namespace}.json"))
          matching_locale_files.each do |path|
            messages = JSON.parse(File.read(path))
            expect(messages.dig(*key.split("."))).to be_present
          end
        end
      end
    end
  end
end
