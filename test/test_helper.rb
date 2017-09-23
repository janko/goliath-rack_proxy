require "bundler/setup"

ENV["MT_NO_EXPECTATIONS"] = "1"

require "minitest/autorun"
require "minitest/pride"
require "minitest/hooks/default"

require "http"

require "open3"
require "tempfile"

class Minitest::Test
  def start_server(ruby, args = [])
    tempfile = Tempfile.new
    tempfile << ruby
    tempfile.open

    command = %W[bundle exec ruby #{tempfile.path} --stdout] + args

    stdin, stdout, stderr, @thread = Open3.popen3(*command)

    HTTP.head("http://localhost:9000") rescue retry

    Thread.new { IO.copy_stream(stderr, $stderr) }

    stdout
  end

  def stop_server
    if @thread
      Process.kill "TERM", @thread[:pid]
      @thread.join # wait for subprocess to finish
      @thread = nil
    end
  end
end
