require 'tmpdir'
require 'fileutils'
require_relative 'check-release'

Dir.mktmpdir('mcp-release-check-') do |root|
  FileUtils.mkdir_p(File.join(root, 'Config'))
  config = File.join(root, 'Config/Version.xcconfig')
  File.write(config, "RELEASE_VERSION = 0.2.0-beta.1\nMARKETING_VERSION = 0.2.0\nCURRENT_PROJECT_VERSION = 1\n")
  File.write(File.join(root, 'LICENSE'), "MIT License\n")
  File.write(File.join(root, 'CHANGELOG.md'), "# Changes\n\n## [0.2.0-beta.1] — 2026-09-06\n\n- Synthetic notes.\n\n## [0.1.0] — 2026-09-01\n\nOld notes.\n")
  raise 'Wrong extracted notes' unless ReleaseMetadata.validate(root, tag: 'v0.2.0-beta.1') == '- Synthetic notes.'
  def rejects
    begin
      yield
    rescue StandardError
      return
    end
    raise 'Invalid metadata was accepted'
  end
  rejects { ReleaseMetadata.validate(root, tag: 'v0.2.0') }
  File.write(config, "RELEASE_VERSION = 0.2.0-dev.1\nMARKETING_VERSION = 0.2.0\nCURRENT_PROJECT_VERSION = 1\n")
  rejects { ReleaseMetadata.validate(root, tag: 'v0.2.0-dev.1') }
  File.write(config, "RELEASE_VERSION = 0.2.0\nMARKETING_VERSION = 0.3.0\nCURRENT_PROJECT_VERSION = 1\n")
  rejects { ReleaseMetadata.validate(root) }
  File.write(config, "RELEASE_VERSION = 0.2.0\nMARKETING_VERSION = 0.2.0\nCURRENT_PROJECT_VERSION = 0\n")
  rejects { ReleaseMetadata.validate(root) }
  File.write(config, "RELEASE_VERSION = 0.2.0\nMARKETING_VERSION = 0.2.0\nCURRENT_PROJECT_VERSION = 2\n")
  rejects { ReleaseMetadata.validate(root, tag: 'v0.2.0') }
end
puts 'OK · Release metadata, notes, mismatched tags and blocked development releases'
