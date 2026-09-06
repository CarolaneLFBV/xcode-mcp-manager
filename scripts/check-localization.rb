#!/usr/bin/env ruby
# Run after an Xcode build, which extracts new localized literals into the catalog.
require 'json'

path = File.expand_path('../MCPManager/Resources/Localizable.xcstrings', __dir__)
catalog = JSON.parse(File.read(path))
# These extracted keys are formatting, product names or technical examples.
verbatim = ['', '%@ · %@', '%@ · PID %d', '%@ · PID %d · %@', '%lld',
            'https://example.com/mcp', 'MCP Manager', 'MCP_API_TOKEN', 'npx', 'OK', 'Xcode']

def units(node)
  return [] unless node.is_a?(Hash)
  return [node.fetch('stringUnit')] if node.key?('stringUnit')
  node.values.flat_map { |value| units(value) }
end

def placeholders(value)
  value.scan(/%(?:\d+\$)?(?:lld|llu|ld|lu|d|u|@|f)/)
       .map { |specifier| specifier.sub(/\d+\$/, '') }.sort
end

failures = []
failures << 'Expected French development language' unless catalog['sourceLanguage'] == 'fr'
catalog.fetch('strings').each do |key, entry|
  next if verbatim.include?(key) || entry['extractionState'] == 'stale'
  %w[fr en].each do |language|
    translations = units(entry.dig('localizations', language))
    if translations.empty?
      failures << "#{language}: missing translation for #{key}"
      next
    end
    translations.each do |unit|
      failures << "#{language}: unfinished translation for #{key}" unless unit['state'] == 'translated'
      failures << "#{language}: empty translation for #{key}" if unit.fetch('value').empty?
      failures << "#{language}: incompatible placeholders for #{key}" unless placeholders(unit.fetch('value')) == placeholders(key)
    end
  end
end
abort failures.join("\n") unless failures.empty?
puts 'OK · FR/EN coverage and interpolation signatures in the extracted String Catalog'
