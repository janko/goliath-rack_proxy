require "test_helper"
require "http"
require "time"
require "timeout"

describe "Goliath::RackProxy" do
  around do |&block|
    Timeout.timeout(10) do
      super(&block)
    end
  end

  after do
    stop_server
  end

  it "implements basic requests" do
    start_server <<~RUBY
      require "goliath/rack_proxy"

      class App < Goliath::RackProxy
        rack_app -> (env) { [200, {"Content-Length" => "5"}, ["Hello"]] }
      end
    RUBY

    response = HTTP.get("http://localhost:9000")

    assert_equal 200,       response.status
    assert_equal "5",       response.headers["Content-Length"]
    assert_equal "Goliath", response.headers["Server"]
    assert_equal "Hello",   response.body.to_s
  end

  it "implements streaming uploads" do
    start_server <<~RUBY
      require "goliath/rack_proxy"

      class App < Goliath::RackProxy
        rack_app -> (env) {
          start_time = Time.now
          content = env["rack.input"].read
          [200, {"Read-Time" => (Time.now - start_time).to_s}, [content]]
        }
      end
    RUBY

    body = Enumerator.new { |y| sleep 1; y << "body" }

    response = HTTP
      .headers("Transfer-Encoding" => "chunked")
      .post("http://localhost:9000", body: body)

    assert_equal "body", response.body.to_s
    assert_in_delta 1, Float(response.headers["Read-Time"]), 0.1
  end

  it "gives rack input IO#read semantics" do
    start_server <<~RUBY
      require "goliath/rack_proxy"

      class App < Goliath::RackProxy
        rack_app -> (env) do
          body = []
          body << env["rack.input"].read(3)
          body << env["rack.input"].read(2, "")
          body << env["rack.input"].read
          body << env["rack.input"].read(3).inspect

          [200, {}, body]
        end
      end
    RUBY

    response = HTTP
      .headers("Transfer-Encoding" => "chunked")
      .post("http://localhost:9000", body: ["he", "llo", " ", "world"])

    assert_equal "hello worldnil", response.body.to_s
  end

  it "can rewind rewindable inputs" do
    start_server <<~RUBY
      require "goliath/rack_proxy"

      class App < Goliath::RackProxy
        rack_app -> (env) do
          env["rack.input"].read
          env["rack.input"].rewind
          [200, {}, [env["rack.input"].read]]
        end
      end
    RUBY

    response = HTTP
      .headers("Transfer-Encoding" => "chunked")
      .post("http://localhost:9000", body: ["foo", "bar", "baz"])

    assert_equal "foobarbaz", response.body.to_s
  end

  it "cannot rewind non-rewindable inputs" do
    start_server <<~RUBY
      require "goliath/rack_proxy"

      class App < Goliath::RackProxy
        rack_app -> (env) { env["rack.input"].rewind }
        rewindable_input false
      end
    RUBY

    response = HTTP
      .headers("Transfer-Encoding" => "chunked")
      .post("http://localhost:9000", body: ["foo", "bar", "baz"])

    assert_equal "#<Errno::ESPIPE: Illegal seek>", response.body.to_s
  end

  it "implements streaming downloads" do
    start_server <<~RUBY
      require "goliath/rack_proxy"

      class App < Goliath::RackProxy
        rack_app -> (env) {
          body = Enumerator.new { |y| sleep 0.5; y << "foo"; sleep 0.5; y << "bar" }
          [200, {"Content-Length" => "6"}, body]
        }
      end
    RUBY

    start_time = Time.now

    response = HTTP.get("http://localhost:9000")

    header_time = Time.now
    assert_equal "6", response.headers["Content-Length"]
    assert_in_delta start_time, header_time, 0.2

    assert_equal "foo", response.body.readpartial
    first_chunk_time = Time.now
    assert_in_delta header_time + 0.5, first_chunk_time, 0.2

    assert_equal "bar", response.body.readpartial
    second_chunk_time = Time.now
    assert_in_delta first_chunk_time + 0.5, second_chunk_time, 0.2

    assert_nil response.body.readpartial
    assert_in_delta second_chunk_time, Time.now, 0.2
  end

  it "closes the response body at correct time" do
    stdout_pipe = start_server <<~RUBY
      require "goliath/rack_proxy"
      require "stringio"

      class App < Goliath::RackProxy
        rack_app -> (env) {
          tempfile = Tempfile.new
          tempfile << "a" * 10*1024*1024
          tempfile.open

          chunks = Enumerator.new do |y|
            if env["async.callback"] # this is what Roda and Sinatra essentially do
              EM.defer { y << tempfile.read(16*1024) until tempfile.eof? }
            else
              y << tempfile.read(16*1024) until tempfile.eof?
            end
          end

          body = Rack::BodyProxy.new(chunks) { tempfile.close! }

          [200, {"Content-Length" => tempfile.size.to_s}, body]
        }
      end
    RUBY

    response = HTTP.get("http://localhost:9000")

    assert_equal "a" * 10*1024*1024, response.body.to_s
    assert_equal response.body.to_s.bytesize.to_s, response.headers["Content-Length"]
  end

  it "accepts parallel requests" do
    start_server <<~RUBY
      require "goliath/rack_proxy"

      class App < Goliath::RackProxy
        rack_app -> (env) {
          env["rack.input"].read
          body = Enumerator.new { |y| sleep 0.5; y << "foo"; sleep 0.5; y << "bar" }
          [200, {"Content-Length" => "6"}, body]
        }
      end
    RUBY

    start_time = Time.now

    5.times.map do
      Thread.new do
        body = Enumerator.new { |y| sleep 0.5; y << "foo"; sleep 0.5; y << "bar" }

        response = HTTP
          .headers("Transfer-Encoding" => "chunked")
          .post("http://localhost:9000", body: body)

        assert_equal "foobar", response.body.to_s
      end
    end.each(&:join)

    assert_in_delta start_time + 2, Time.now, 0.1
  end

  it "starts sending the response only after client has sent all data" do
    start_server <<~RUBY
      require "goliath/rack_proxy"

      class App < Goliath::RackProxy
        rack_app -> (env) { [200, {}, ["content"]] }
      end
    RUBY

    body = Enumerator.new { |y| sleep 0.5; y << "foo"; sleep 0.5; y << "bar" }

    response = HTTP
      .headers("Transfer-Encoding" => "chunked")
      .post("http://localhost:9000", body: body)

    assert_equal "content", response.body.to_s
  end

  it "catches exceptions when calling the Rack application" do
    stdout_pipe = start_server <<~RUBY
      require "goliath/rack_proxy"

      class App < Goliath::RackProxy
        rack_app -> (env) { 10 / 0 }
      end
    RUBY

    response = HTTP.get("http://localhost:9000")

    assert_equal "#<ZeroDivisionError: divided by 0>", response.body.to_s
    assert_equal response.body.to_s.bytesize.to_s, response.headers["Content-Length"]
    assert_includes stdout_pipe.readpartial(16*1024), "divided by 0 (ZeroDivisionError)"
  end

  it "doesn't display exceptions on production" do
    stdout_pipe = start_server <<~RUBY, ["--environment", "production"]
      require "goliath/rack_proxy"

      class App < Goliath::RackProxy
        rack_app -> (env) { 10 / 0 }
      end
    RUBY

    response = HTTP.get("http://localhost:9000")

    assert_equal "An error occurred", response.body.to_s
    assert_equal response.body.to_s.bytesize.to_s, response.headers["Content-Length"]
    assert_includes stdout_pipe.readpartial(16*1024), "divided by 0 (ZeroDivisionError)"
  end

  it "handles keep-alive connections" do
    start_server <<~RUBY
      require "goliath/rack_proxy"

      class App < Goliath::RackProxy
        rack_app -> (env) { [200, {"Content-Length" => "7"}, ["content"]] }
      end
    RUBY

    client = HTTP.persistent("http://localhost:9000")

    assert_equal "content", client.get("/").to_s
    assert_equal "content", client.get("/").to_s

    client = HTTP::Client.new

    assert_equal "content", client.get("http://localhost:9000").to_s
    assert_equal "content", client.get("http://localhost:9000").to_s
  end

  it "catches exceptions that occurred during sending the response" do
    stdout_pipe = start_server <<~RUBY
      require "goliath/rack_proxy"

      class App < Goliath::RackProxy
        rack_app -> (env) {
          [200, {"Content-Length" => "100"}, Enumerator.new { |y| 10 / 0 }]
        }
      end
    RUBY

    response = HTTP.get("http://localhost:9000")

    assert_equal "HTTP/1.1 500 Internal Server Error\r\n\r\n", response.body.to_s # read the whole response
    assert_includes stdout_pipe.readpartial(16*1024), "divided by 0 (ZeroDivisionError)"
  end

  # https://github.com/postrank-labs/goliath/issues/210
  it "allows generating full URLs" do
    start_server <<~RUBY
      require "goliath/rack_proxy"

      class App < Goliath::RackProxy
        rack_app -> (env) { [200, {}, [Rack::Request.new(env).url]] }
      end
    RUBY

    body = Enumerator.new { |y| sleep 0.5; y << "foo"; sleep 0.5; y << "bar" }

    response = HTTP.get("http://localhost:9000/foo")

    assert_equal "http://localhost:9000/foo", response.body.to_s
  end
end
