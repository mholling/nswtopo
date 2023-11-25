require_relative "lib/nswtopo/version"
Gem::Specification.new do |spec|
  spec.name                  = "nswtopo"
  spec.version               = String(NSWTopo::VERSION)
  spec.summary               = "A vector topographic mapping tool"
  spec.authors               = ["Matthew Hollingworth"]
  spec.homepage              = "https://github.com/mholling/nswtopo"
  spec.license               = "AGPL-3.0"
  spec.files                 = Dir["lib/**/*.rb", "bin/nswtopo", "docs/**/*.md", "COPYING"]
  spec.required_ruby_version = ">= 3.1.4"
  spec.executables  << "nswtopo"
  spec.requirements << "GDAL >= v3.8"
  spec.requirements << "Google Chrome >= v112"
end
