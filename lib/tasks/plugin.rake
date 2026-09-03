namespace :plugin do
  desc "Show the durable data a plugin owns (plugin:data[name])"
  task :data, [ :name ] => :environment do |_t, args|
    name = args[:name].presence or abort("usage: bin/rails 'plugin:data[build_cache]'")
    report = Syrus::PluginPurge.new(name).report

    if report.empty?
      puts "#{name}: owns no tables."
      next
    end

    puts "#{name} owns #{report.tables.size} table(s), #{report.total_rows} row(s):"
    report.row_counts.each { |table, count| puts "  #{table}: #{count} row(s)" }
    puts
    puts "Run 'plugin:purge[#{name}]' to drop them. This is irreversible."
  end

  desc "Drop the tables a plugin owns (plugin:purge[name]) - irreversible"
  task :purge, [ :name ] => :environment do |_t, args|
    name = args[:name].presence or abort("usage: bin/rails 'plugin:purge[build_cache]'")
    report = Syrus::PluginPurge.new(name).report

    if report.empty?
      puts "#{name}: owns no tables, nothing to purge."
      next
    end

    puts "About to DROP #{report.tables.size} table(s) holding #{report.total_rows} row(s):"
    report.row_counts.each { |table, count| puts "  #{table}: #{count} row(s)" }
    print "Type the plugin name to confirm: "
    confirmation = $stdin.gets.to_s.strip
    abort("Aborted.") unless confirmation == name

    dropped = Syrus::PluginPurge.new(name).purge!
    puts "Dropped: #{dropped.join(', ')}"
  rescue Syrus::PluginPurge::PluginStillInstalled => e
    abort(e.message)
  end
end
