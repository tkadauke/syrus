require "rails_helper"

RSpec.describe "plugin admin page contracts" do
  it "declares installed admin pages with frontend, i18n, and SPA route metadata" do
    if Syrus::PluginRegistry.boot_snapshot
      Syrus::PluginRegistry.restore(Syrus::PluginRegistry.boot_snapshot)
    end

    manifests = Syrus::PluginRegistry.all_plugins
    admin_page_manifests = manifests.select { |manifest| manifest.provides.key?(:admin_page) }

    expect(admin_page_manifests).not_to be_empty

    admin_page_manifests.each do |manifest|
      metadata = manifest.metadata.with_indifferent_access
      frontend_routes = metadata.dig(:frontend, :routes).to_h
      i18n_patterns = Array(metadata.dig(:frontend, :i18n))
      spa_routes = Array(metadata[:routes]).map { |route| route.to_h.symbolize_keys }
        .select { |route| route[:controller].to_s == "spa#show" }
        .map { |route| route[:path].to_s }

      Array(manifest.provides[:admin_page]).each do |provider|
        Array(provider.admin_pages).each do |raw_page|
          page = raw_page.to_h.symbolize_keys

          expect(page[:id].to_s).to start_with("#{manifest.name}.")
          expect(page[:label_key]).to be_present
          expect(page[:component]).to be_present
          expect(frontend_routes.keys).to include(page[:component])
          expect(spa_routes).to include(page.fetch(:path).to_s)

          namespace, key = page[:label_key].to_s.split(":", 2)
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
