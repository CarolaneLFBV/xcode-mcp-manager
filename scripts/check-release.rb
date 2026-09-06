#!/usr/bin/env ruby
# Validates metadata without changing git state, tags or releases.
require 'date'

module ReleaseMetadata
  # Supported SemVer subset: stable, alpha.N, beta.N, rc.N and development builds.
  PATTERN = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(dev|alpha|beta|rc)\.(0|[1-9]\d*))?\z/

  def self.validate(root, tag: nil)
    fields = File.read(File.join(root, 'Config/Version.xcconfig')).scan(/^([A-Z_]+)\s*=\s*(\S+)\s*$/).to_h
    version = fields.fetch('RELEASE_VERSION')
    match = PATTERN.match(version) or raise 'Unsupported release version'
    raise 'Marketing version must match SemVer core' unless fields['MARKETING_VERSION'] == match.captures.first(3).join('.')
    raise 'Build number must be a positive integer' unless /\A[1-9]\d*\z/.match?(fields.fetch('CURRENT_PROJECT_VERSION'))
    return version unless tag
    raise 'Tag must match RELEASE_VERSION exactly' unless tag == "v#{version}"
    raise 'Development builds cannot be released' if match[4] == 'dev'
    raise 'MIT license missing' unless File.read(File.join(root, 'LICENSE')).start_with?("MIT License\n")
    changelog = File.read(File.join(root, 'CHANGELOG.md'))
    heading = /^## \[#{Regexp.escape(version)}\] — (\d{4}-\d{2}-\d{2})\s*$/
    matches = changelog.scan(heading)
    raise 'Expected exactly one dated changelog section for this version' unless matches.length == 1
    Date.iso8601(matches.first.first)
    notes = changelog.split(heading, 2).last.split(/^## /, 2).first.strip
    raise 'Release notes are empty' if notes.empty?
    notes
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    root = File.expand_path('..', __dir__)
    raise 'Usage: ruby scripts/check-release.rb [vVERSION]' if ARGV.length > 1
    puts ReleaseMetadata.validate(root, tag: ARGV.first)
  rescue StandardError => error
    warn error.message
    exit 1
  end
end
