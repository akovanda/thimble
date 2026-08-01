# frozen_string_literal: true

require_relative 'lib/thimble/version'

Gem::Specification.new do |spec|
  spec.name        = 'thimble'
  spec.version     = Thimble::VERSION
  spec.summary     = 'Bounded concurrency and streaming pipelines for Ruby'
  spec.description = <<~DESCRIPTION
    Thimble coordinates bounded thread or process workers over enumerable and
    streaming inputs. It provides explicit backpressure, batch sizing, shared
    concurrency limits, and deterministic worker error propagation.
  DESCRIPTION
  spec.authors     = ['Andrew Kovanda']
  spec.email       = 'andrew.kovanda@gmail.com'
  spec.homepage    = 'https://github.com/akovanda/thimble'
  spec.license     = 'MIT'
  spec.required_ruby_version = '>= 3.3.0'
  spec.require_paths = ['lib']

  spec.files = Dir[
    'lib/**/*',
    'README.md',
    'ROADMAP.md',
    'CHANGELOG.md',
    'LICENSE*'
  ]

  # These standard-library components are shipped as versioned default gems.
  spec.add_dependency 'logger', '~> 1.6'
  spec.add_dependency 'securerandom', '>= 0.3', '< 0.5'

  spec.metadata = {
    'source_code_uri'       => 'https://github.com/akovanda/thimble',
    'bug_tracker_uri'       => 'https://github.com/akovanda/thimble/issues',
    'changelog_uri'         => 'https://github.com/akovanda/thimble/blob/master/CHANGELOG.md',
    'documentation_uri'     => 'https://github.com/akovanda/thimble#readme',
    'rubygems_mfa_required' => 'true'
  }
end
