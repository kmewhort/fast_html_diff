# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'fast_html_diff/version'

Gem::Specification.new do |spec|
  spec.name          = "fast_html_diff"
  spec.version       = FastHtmlDiff::VERSION
  spec.authors       = ["Kent Mewhort"]
  spec.email         = ["kent@openissues.ca"]
  spec.description   = %q{Performs a diff on two HTML inputs, outputting the result as HTML.}
  spec.summary       = %q{Performs a diff on two HTML inputs, outputting the result as HTML.}
  spec.homepage      = ""
  spec.license       = "BSD"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 1.3"
  spec.add_development_dependency "rake"
  spec.add_runtime_dependency "nokogiri"
end
