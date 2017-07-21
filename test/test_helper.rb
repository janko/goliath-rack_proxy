require "bundler/setup"

ENV["MT_NO_EXPECTATIONS"] = "1"

require "minitest/autorun"
require "minitest/pride"

require "goliath/rack_proxy"

# don't automatically start the Goliath server in tests
Goliath.run_app_on_exit = false
