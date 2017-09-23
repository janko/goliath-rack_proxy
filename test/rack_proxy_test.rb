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
        use Rack::Head
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
        use Rack::Head
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
        use Rack::Head
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
        use Rack::Head
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
        use Rack::Head
        rack_app -> (env) { env["rack.input"].rewind }
        rewindable_input false
      end
    RUBY

    response = HTTP
      .headers("Transfer-Encoding" => "chunked")
      .post("http://localhost:9000", body: ["foo", "bar", "baz"])

    assert_equal "Illegal seek", response.body.to_s
  end

  it "implements streaming downloads" do
    start_server <<~RUBY
      require "goliath/rack_proxy"

      class App < Goliath::RackProxy
        use Rack::Head
        rack_app -> (env) {
          body = Enumerator.new { |y| sleep 0.5; y << "a"*16*1024; sleep 0.5; y << "b"*16*1024 }
          [200, {"Content-Length" => (32*1024).to_s}, body]
        }
      end
    RUBY

    start_time = Time.now

    response = HTTP.get("http://localhost:9000")

    header_time = Time.now
    assert_equal (32*1024).to_s, response.headers["Content-Length"]
    assert_in_delta start_time, header_time, 0.2

    assert_equal "a"*16*1024, response.body.readpartial
    first_chunk_time = Time.now
    assert_in_delta header_time + 0.5, first_chunk_time, 0.2

    assert_equal "b"*16*1024, response.body.readpartial
    second_chunk_time = Time.now
    assert_in_delta first_chunk_time + 0.5, second_chunk_time, 0.2

    assert_nil response.body.readpartial
    assert_in_delta second_chunk_time, Time.now, 0.2
  end

  it "doesn't break when sent request body isn't read by the rack app" do
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

  it "prevents Sinatra from calling EM.defer when streaming the response" do
    start_server <<~RUBY
      require "goliath/rack_proxy"

      class App < Goliath::RackProxy
        use Rack::Head
        rack_app -> (env) {
          body = Enumerator.new do |y|
            if env["async.callback"]
              EM.defer { y << "foo" } # this is what Sinatra essential does
            else
              y << "foo"
            end
          end

          [200, {"Content-Length" => "3"}, body]
        }
      end
    RUBY

    response = HTTP.get("http://localhost:9000")

    assert_equal "foo", response.body.to_s
    assert_equal "3",   response.headers["Content-Length"]
  end
end
