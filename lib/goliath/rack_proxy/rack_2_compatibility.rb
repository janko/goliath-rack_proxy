require "rack"

# Async-rack attempts to require files that exist only in Rack 1.x even on Rack
# 2.x, so we patch that behaviour to allow users to use this gem with Rack 2.x apps.
module Kernel
  if Rack.release >= "2.0.0"
    alias original_rubygems_require require

    def require(file)
      case file
      when "rack/commonlogger"   then original_rubygems_require("rack/common_logger")
      when "rack/conditionalget" then original_rubygems_require("rack/conditional_get")
      when "rack/showstatus"     then original_rubygems_require("rack/show_status")
      else
        original_rubygems_require(file)
      end
    end
  end
end
