names = Syrus::PluginRegistry.all_plugins.map(&:name)
raise "relocation fixture unexpectedly loaded without either root" if names.include?("relocatable_plugin")

puts "plugin absence boot passed"
