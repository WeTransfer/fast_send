# encoding: utf-8

require 'rubygems'
require 'bundler'
begin
  Bundler.setup(:default, :development)
rescue Bundler::BundlerError => e
  $stderr.puts e.message
  $stderr.puts "Run `bundle install` to install missing gems"
  exit e.status_code
end
require 'rake'

require 'jeweler'
require_relative 'lib/fast_send'
Jeweler::Tasks.new do |gem|
  gem.version = FastSend::VERSION
  gem.name = "fast_send"
  gem.homepage = "https://gitlab.wetransfer.net/julik/fast_send"
  gem.license = "Proprietary"
  gem.description = %Q{Send bursts of large files quickly via Rack}
  gem.summary = %Q{and do so bypassing the Ruby VM}
  gem.email = "me@julik.nl"
  gem.authors = ["Julik Tarkhanov"]
  # dependencies defined in Gemfile
end
# Jeweler::RubygemsDotOrgTasks.new

require 'rspec/core'
require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new(:spec) do |spec|
  spec.rspec_opts = ["-c"]
  spec.pattern = FileList['spec/**/*_spec.rb']
end

task :default => :spec

