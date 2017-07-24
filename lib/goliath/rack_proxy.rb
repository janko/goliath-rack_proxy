# frozen-string-literal: true
require "goliath/rack_proxy/rack_2_compatibility"
require "goliath"
require "tempfile"

module Goliath
  class RackProxy < Goliath::API
    # Rack app to proxy the incoming requests to.
    def self.rack_app(app)
      rack_proxy_options[:rack_app] = app
    end

    # Whether the input should be rewindable, i.e. cached onto disk.
    def self.rewindable_input(value)
      rack_proxy_options[:rewindable_input] = value
    end

    # Custom user-defined options.
    def self.rack_proxy_options
      @rack_proxy_options ||= {}
    end

    # Called when request headers were parsed.
    def on_headers(env, headers)
      # assign a streaming input that acts as a bidirectional pipe
      env["rack_proxy.input"] = RackInput.new(rewindable: self.class.rack_proxy_options.fetch(:rewindable_input, true))
      rack_app = self.class.rack_proxy_options.fetch(:rack_app)

      # start the rack request asynchronously with the created rack input
      async_rack_call rack_app, env.merge("rack.input" => env["rack_proxy.input"])
    end

    # Called on each request body chunk received from the client.
    def on_body(env, data)
      # write data to the input, which will be read by the Rack app
      env["rack_proxy.input"].write(data)
    end

    # Called at the end of the request (after #response) or on client disconnect.
    def on_close(env)
      # reading the request body has finished, so we close write end of the input
      env["rack_proxy.input"].close_write
    end

    # Called after all the data has been received from the client.
    def response(env)
      # reading the request body has finished, so we close write end of the input
      env["rack_proxy.input"].close_write

      # prevent Goliath from sending a response, we will send it once the
      # asynchronous request to the rack app finishes
      nil
    end

    private

    # Spawns a thread and initiates the call to the Rack application, which
    # will be reading from Rack input that is being written to in #on_body. Once
    # the request has finished, we stream the response back to the client.
    def async_rack_call(rack_app, env)
      env["goliath.request"] = env["stream.start"].binding.receiver # https://github.com/postrank-labs/goliath/pull/341

      # spawn a thread for the request
      EM.defer do
        rack_response = make_request(rack_app, env)

        # wait for client to stop sending data before sending the response
        env["goliath.request"].callback do
          # spawn a thread for the response
          EM.defer { send_response(rack_response, env) }
        end
      end
    end

    def make_request(rack_app, env)
      # call the rack app with some patches
      rack_app.call env.merge(
        "rack.url_scheme" => env["options"][:ssl] ? "https" : "http", # https://github.com/postrank-labs/goliath/issues/210
        "async.callback"  => nil, # prevent Roda/Sinatra from calling EventMachine while streaming the response
      )
    rescue Exception => exception
      # log the exception that occurred
      log_exception(exception, env)

      # return a generic error message on production, or a more detailed one otherwise
      body    = Goliath.env?(:production) ? ["An error occurred"] : [exception.inspect]
      headers = {"Content-Length" => body[0].bytesize.to_s}

      [500, headers, body]
    ensure
      # request has finished, so we close the read end of the rack input
      env["rack.input"].close_read
    end

    # Streams the response to the client.
    def send_response(rack_response, env)
      request    = env["goliath.request"]
      connection = request.conn
      response   = request.response

      response.status, response.headers, response.body = rack_response
      response.each { |data| connection.send_data(data) }

      connection.terminate_request(keep_alive?(env))
    rescue Exception => exception
      # log the exception that occurred
      log_exception(exception, env)

      # communicate that sending response failed and close the connection
      connection.send_data("HTTP/1.1 500 Internal Server Error\r\n\r\n")
      connection.terminate_request(false)
    ensure
      # log the response information
      log_response(response, env)
    end

    # Returns whether the TCP connection should be kept alive.
    def keep_alive?(env)
      if env["HTTP_VERSION"] >= "1.1"
        # HTTP 1.1: all requests are persistent requests, client must
        # send a "Connection: close" header to indicate otherwise
        env["HTTP_CONNECTION"].to_s.downcase != "close"
      elsif env["HTTP_VERSION"] == "1.0"
        # HTTP 1.0: all requests are non keep-alive, client must
        # send a "Connection: Keep-Alive" to indicate otherwise
        env["HTTP_CONNECTION"].to_s.downcase == "keep-alive"
      end
    end

    # Logs the response in the Rack::CommonLogger format.
    def log_response(response, env)
      length = response.headers["Content-Length"]
      length = nil if length.to_s == "0"

      # log the response as Goliath would log it
      env.logger.info '%s - %s [%s] "%s %s%s %s" %d %s %0.4f' % [
        env["HTTP_X_FORWARDED_FOR"] || env["REMOTE_ADDR"] || "-",
        env["REMOTE_USER"] || "-",
        Time.now.strftime("%d/%b/%Y:%H:%M:%S %z"),
        env["REQUEST_METHOD"],
        env["PATH_INFO"],
        env["QUERY_STRING"].empty? ? "" : "?#{env["QUERY_STRING"]}",
        env["HTTP_VERSION"],
        response.status,
        length || "-",
        Time.now.to_f - env[:start_time],
      ]
    end

    # Logs the exception and adds it to the env hash.
    def log_exception(exception, env)
      # mimic how Ruby would display the error
      stderr = "#{exception.backtrace[0]}: #{exception.message} (#{exception.class})\n".dup
      exception.backtrace[1..-1].each do |line|
        stderr << "    from #{line}\n"
      end
      env.logger.error(stderr)

      # save the exception in the env hash
      env["rack.exception"] = exception
    end

    # IO-like object that acts as a bidirectional pipe, which returns the data
    # that has been written to it.
    class RackInput
      def initialize(rewindable: true)
        @data_queue = Queue.new
        @cache      = Tempfile.new("goliath-rack_input") if rewindable
        @buffer     = nil
      end

      # Pops chunks of data from the queue and implements
      # `IO#read(length = nil, outbuf = nil)` semantics.
      def read(length = nil, outbuf = nil)
        data = outbuf.clear if outbuf
        data = @cache.read(length, outbuf) if @cache && !@cache.eof?

        loop do
          remaining_length = length - data.bytesize if data && length

          break if remaining_length == 0

          @buffer = @data_queue.pop or break if @buffer.nil?

          buffered_data = if remaining_length && remaining_length < @buffer.bytesize
                            @buffer.byteslice(0, remaining_length)
                          else
                            @buffer
                          end

          if data
            data << buffered_data
          else
            data = buffered_data
          end

          @cache.write(buffered_data) if @cache

          if buffered_data.bytesize < @buffer.bytesize
            @buffer = @buffer.byteslice(buffered_data.bytesize..-1)
          else
            @buffer = nil
          end
        end

        data.to_s unless length && (data.nil? || data.empty?)
      end

      # Pushes data to the queue, which is then popped in #read.
      def write(data)
        @data_queue.push(data) unless @data_queue.closed?
      end

      # Rewinds the cache IO if it's configured, otherwise raises Errno::ESPIPE
      # exception, which mimics the behaviour of caling #rewind on
      # non-rewindable IOs such as pipes, sockets, and ttys.
      def rewind
        raise Errno::ESPIPE if @cache.nil? # raised by other non-rewindable IOs
        @cache.rewind
      end

      # Closes the queue and deletes the cache IO.
      def close_read
        @data_queue.close
        @cache.close! if @cache
      end

      # Closes the queue, which prevents fruther pushing, but #read can still
      # pop remaining chunks from it.
      def close_write
        @data_queue.close
      end

      # Conforming to the Rack specification.
      def close
        # no-op
      end
    end
  end
end
