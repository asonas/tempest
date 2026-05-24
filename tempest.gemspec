require_relative "lib/tempest/version"

Gem::Specification.new do |spec|
  spec.name = "tempest-rb"
  spec.version = Tempest::VERSION
  spec.authors = ["Yuya Fujiwara"]
  spec.email = ["asonas@ivry.jp"]

  spec.summary = "A terminal client for Bluesky, inspired by earthquake."
  spec.description = "tempest is a REPL-style terminal client for Bluesky built on AT Protocol and Ruby 4.0."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE"]
  spec.bindir = "exe"
  spec.executables = ["tempest"]
  spec.require_paths = ["lib"]

  spec.add_dependency "base64", "~> 0.2"
  spec.add_dependency "logger", "~> 1.6"
  spec.add_dependency "reline", "~> 0.6"
  spec.add_dependency "async", "~> 2.21"
  spec.add_dependency "async-websocket", "~> 0.28"
  spec.add_dependency "ruby-vips", "~> 2.2"
end
