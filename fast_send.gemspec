# -*- encoding: utf-8 -*-
# stub: fast_send 1.1.2 ruby lib
require File.dirname(__FILE__) + '/lib/fast_send/version'
Gem::Specification.new do |s|
  s.name = "fast_send"
  s.version = FastSend::VERSION
  s.required_rubygems_version = Gem::Requirement.new(">= 0") if s.respond_to? :required_rubygems_version=
  s.require_paths = ["lib"]
  s.authors = ["Julik Tarkhanov"]
  s.date = Time.now.utc.strftime("%Y-%m-%d")
  s.description = "Send bursts of large files quickly via Rack"
  s.email = "me@julik.nl"
  s.extra_rdoc_files = [
    "LICENSE.txt",
    "README.md"
  ]
  s.files = `git ls-files -z`.split("\x0")
  s.homepage = "https://github.com/WeTransfer/fast_send"
  s.licenses = ["MIT"]
  s.rubygems_version = "2.4.5.1"
  s.summary = "and do so bypassing the Ruby VM"

  s.add_development_dependency("rake", [">= 0"])
  s.add_development_dependency("rspec", ["~> 3"])
  s.add_development_dependency("puma", [">= 0"])
  s.add_development_dependency("sendfile", [">= 0"])
end
