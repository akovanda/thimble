# frozen_string_literal: true

require_relative 'lib/thimble/version'

Gem::Specification.new do |s|
  s.name        = 'thimble'
  s.version     = Thimble::VERSION
  s.summary     = 'Concurrency and Parallelism gem that uses blocks to move data'
  s.description = 'Thimble is a ruby gem for parallelism and concurrency. It allows you to decide if you want to use separate processes, or if you want to use threads in ruby. It allows you to create stages with a thread safe queue, and break apart large chunks of work.'
  s.authors     = ['Andrew Kovanda']
  s.email       = 'andrew.kovanda@gmail.com'
  s.homepage    = 'https://github.com/akovanda/thimble'
  s.license     = 'MIT'
  s.required_ruby_version = '>= 3.0.0'
  s.require_paths = ['lib']

  # Package the important files
  s.files = Dir[
    'lib/**/*',
    'README.md',
    'LICENSE*'
  ]

  # Runtime dependencies (stdlib default gems moving out by Ruby 3.5)
  s.add_dependency 'logger'
  s.add_dependency 'ostruct'

  # Helpful metadata for RubyGems.org
  s.metadata = {
    'source_code_uri'       => 'https://github.com/akovanda/thimble',
    'bug_tracker_uri'       => 'https://github.com/akovanda/thimble/issues',
    'changelog_uri'         => 'https://github.com/akovanda/thimble/releases',
    'documentation_uri'     => 'https://github.com/akovanda/thimble#readme',
    'rubygems_mfa_required' => 'true'
  }
end
