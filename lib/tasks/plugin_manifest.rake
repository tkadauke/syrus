namespace :plugin_manifest do
  desc "Generate and store the plugin desired-state signing key"
  task keygen: :environment do
    key = PluginDesiredState::SigningKey.generate!
    puts "SYRUS_PLUGIN_MANIFEST_PUBLIC_KEY=#{key.public_key}"
  end
end
