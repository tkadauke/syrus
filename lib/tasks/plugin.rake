namespace :plugin do
  desc "Show the durable data a plugin owns (plugin:data[name])"
  task :data, [ :name ] => :environment do |_t, args|
    name = args[:name].presence or abort("usage: bin/rails 'plugin:data[build_cache]'")
    report = Syrus::PluginPurge.new(name).report

    if report.empty?
      puts "#{name}: owns no data."
      next
    end

    puts "#{name} owns #{report.tables.size} table(s), #{report.inline_fields.size} inline field(s), #{report.total_rows} row(s):"
    report.row_counts.each { |table, count| puts "  #{table}: #{count} row(s)" }
    report.inline_row_counts.each { |table, count| puts "  #{table}: #{count} plugin-owned row(s)" }
    report.inline_fields.each { |field| puts "  #{field.table}.#{field.column}: inline field" }
    report.other_data.each { |line| puts "  #{line}" }
    puts
    puts "Run 'plugin:purge[#{name}]' to drop them. This is irreversible."
  end

  desc "Drop the tables a plugin owns (plugin:purge[name]) - irreversible"
  task :purge, [ :name ] => :environment do |_t, args|
    name = args[:name].presence or abort("usage: bin/rails 'plugin:purge[build_cache]'")
    report = Syrus::PluginPurge.new(name).report

    if report.empty?
      puts "#{name}: owns no data, nothing to purge."
      next
    end

    puts "About to remove #{report.tables.size} table(s), #{report.inline_fields.size} inline field(s), and #{report.total_rows} row(s):"
    report.row_counts.each { |table, count| puts "  #{table}: #{count} row(s)" }
    report.inline_row_counts.each { |table, count| puts "  delete #{count} plugin-owned row(s) from #{table}" }
    report.inline_fields.each { |field| puts "  drop inline field #{field.table}.#{field.column}" }
    report.other_data.each { |line| puts "  and remove #{line}" }
    print "Type the plugin name to confirm: "
    confirmation = $stdin.gets.to_s.strip
    abort("Aborted.") unless confirmation == name

    dropped = Syrus::PluginPurge.new(name).purge!
    puts "Removed: #{dropped.join(', ')}"
  rescue Syrus::PluginPurge::PluginStillInstalled => e
    abort(e.message)
  end
end
