require "bundler/setup"

ENV["MT_NO_EXPECTATIONS"] = "1"

require "minitest/autorun"
require "minitest/pride"

require "open3"
require "tempfile"
require "http"

def start_server(ruby, args = [])
  tempfile = Tempfile.new
  tempfile << ruby
  tempfile.open

  command = %W[bundle exec ruby #{tempfile.path} --stdout] + args

  _, stdout_pipe, _, $thread = Open3.popen3(*command)

  HTTP.get("http://localhost:9000") rescue retry

  stdout_pipe
end

def stop_server
  Process.kill "TERM", $thread[:pid] if $thread
  $thread = nil
end
