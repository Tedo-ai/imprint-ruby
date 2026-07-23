# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task default: :spec

namespace :imprint do
  desc "Record a deployment marker (auto-detects revision/actor from env + git)"
  task :deploy_marker do
    require "imprint"
    result = Imprint.deployment_marker
    puts "[Imprint] deployment marker recorded: #{result.inspect}"
  end
end
