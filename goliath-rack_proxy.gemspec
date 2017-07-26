Gem::Specification.new do |gem|
  gem.name         = "goliath-rack_proxy"
  gem.version      = "0.1.3"

  gem.required_ruby_version = ">= 2.1"

  gem.summary      = "Allows you to use Goliath as a web server for your Rack app, giving you streaming requests and responses."

  gem.homepage     = "https://github.com/janko-m/goliath-rack_proxy"
  gem.authors      = ["Janko Marohnić"]
  gem.email        = ["janko.marohnic@gmail.com"]
  gem.license      = "MIT"

  gem.files        = Dir["README.md", "LICENSE.txt", "lib/**/*.rb", "*.gemspec"]
  gem.require_path = "lib"

  gem.add_dependency "goliath", ">= 1.0.5", "< 2"

  gem.add_development_dependency "rake", "~> 11.1"
  gem.add_development_dependency "minitest", "~> 5.8"
  gem.add_development_dependency "minitest-hooks"
  gem.add_development_dependency "http"
  gem.add_development_dependency "rack", "~> 2.0"
end
