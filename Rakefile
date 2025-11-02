# frozen_string_literal: true

require 'rspec/core/rake_task'
require 'fileutils'
require 'open3'

RSpec::Core::RakeTask.new(:spec)

desc 'Run the test suite'
task default: :spec

# --- Release helpers ---
module Release
  module_function

  def version_file
    File.expand_path('lib/thimble/version.rb', __dir__)
  end

  def current_version
    content = File.read(version_file)
    m = content.match(/VERSION\s*=\s*['"](\d+\.\d+\.\d+)['"]/)
    abort 'Could not find VERSION in lib/thimble/version.rb' unless m
    m[1]
  end

  def bump_version(level)
    major, minor, patch = current_version.split('.').map(&:to_i)
    case level
    when 'major'
      major += 1; minor = 0; patch = 0
    when 'minor'
      minor += 1; patch = 0
    when 'bug', 'patch', 'fix'
      patch += 1
    else
      abort "Unknown level '#{level}'. Use major|minor|bug (patch)."
    end
    new_version = [major, minor, patch].join('.')
    write_version(new_version)
    new_version
  end

  def write_version(v)
    path = version_file
    content = File.read(path)
    new_content = content.sub(/VERSION\s*=\s*['"]\d+\.\d+\.\d+['"]/,
                              "VERSION = '#{v}'")
    File.write(path, new_content)
  end

  def sh!(cmd)
    puts ">>> #{cmd}"
    return if ENV['DRY_RUN'] == '1'
    ok = system(cmd)
    ok || abort("Command failed: #{cmd}")
  end

  def ensure_clean_worktree!
    return if ENV['PUBLISH_DIRTY'] == '1'
    out, _ = Open3.capture2('git status --porcelain')
    abort 'Working tree is not clean. Commit or stash changes, or set PUBLISH_DIRTY=1.' unless out.strip.empty?
  end

  def gem_name
    'thimble'
  end

  def build_gem(version)
    sh!("gem build #{gem_name}.gemspec")
    FileUtils.mkdir_p('pkg')
    built = "#{gem_name}-#{version}.gem"
    FileUtils.mv(built, File.join('pkg', built)) if File.exist?(built)
    File.join('pkg', built)
  end

  def git_commit_tag_push(version)
    sh!('git add lib/thimble/version.rb')
    sh!("git commit -m 'Bump version to #{version}'")
    sh!("git tag v#{version} -m 'Release v#{version}'")
    sh!('git push')
    sh!('git push --tags')
  end

  def push_gem(path)
    sh!("gem push #{path}")
  end
end

# rake publish[major|minor|bug]
desc 'Bump version (default: minor), run tests, build, tag, and push gem. Use DRY_RUN=1 to preview. Allow dirty tree with PUBLISH_DIRTY=1.'
task :publish, [:level] do |_t, args|
    level = (args[:level] || 'minor').to_s.downcase

    Release.ensure_clean_worktree!

    # Run tests first
    Rake::Task[:spec].invoke

    # Bump version
    new_version = Release.bump_version(level)
    puts "New version: #{new_version}"

    # Build gem
    gem_path = Release.build_gem(new_version)

    # Commit + tag + push
    Release.git_commit_tag_push(new_version)

    # Push gem to RubyGems
    Release.push_gem(gem_path)

    puts "Published #{gem_path} as v#{new_version}"
end
