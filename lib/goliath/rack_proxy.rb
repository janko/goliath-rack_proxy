# frozen-string-literal: true
require "goliath/rack_proxy/rack_2_compatibility"
require "goliath"
require "tempfile"
require "fiber"

module Goliath
  class RackProxy < Goliath::API
    # Rack app to proxy the incoming requests to.
    def self.rack_app(app)
      rack_proxy_options[:rack_app] = app
    end

    # Whether the request body should be rewindable.
    def self.rewindable_input(value)
      rack_proxy_options[:rewindable_input] = value
    end

    # Custom user-defined options.
    def self.rack_proxy_options
      @rack_proxy_options ||= {}
    end

    # Starts the request to the given Rack application.
    def on_headers(env, headers)
      rack_app         = self.class.rack_proxy_options.fetch(:rack_app)
      rewindable_input = self.class.rack_proxy_options.fetch(:rewindable_input, true)

      env["rack_proxy.call"] = RackCall.new(rack_app, env, rewindable_input: rewindable_input)
      env["rack_proxy.call"].resume
    end

    # Resumes the Rack request with the received request body data.
    def on_body(env, data)
      env["rack_proxy.call"].resume(data)
    end

    # Resumes the Rack request with no more data.
    def on_close(env)
      env["rack_proxy.call"].resume
    end

    # Resumes the Rack request with no more data.
    def response(env)
      env["rack_proxy.call"].resume
    end

    private

    # Allows "curry-calling" the Rack application, resuming the call as we're
    # receiving more request body data.
    class RackCall
      def initialize(app, env, rewindable_input: true)
        @app              = app
        @env              = env
        @rewindable_input = rewindable_input
      end

      def resume(data = nil)
        @result = fiber.resume(data) if fiber.alive?
        @result
      end

      private

      # Calls the Rack application inside a Fiber, using the RackInput object as
      # the request body. When the Rack application wants to read request body
      # data that hasn't been received yet, the execution is automatically
      # paused so that the event loop can go on.
      def fiber
        @fiber ||= Fiber.new do
          rack_input = RackInput.new(rewindable: @rewindable_input) { Fiber.yield }

          result = @app.call @env.merge(
            "rack.input"     => rack_input,
            "async.callback" => nil, # prevent Roda/Sinatra from calling EventMachine while streaming the response
          )

          rack_input.close

          result
        end
      end
    end

    # IO-like object that conforms to the Rack specification for the request
    # body ("rack input"). It takes a block which produces chunks of data, and
    # makes this data retrievable through the IO#read interface. When rewindable
    # caches the retrieved content onto disk.
    class RackInput
      def initialize(rewindable: true, &next_chunk)
        @next_chunk = next_chunk
        @cache      = Tempfile.new("goliath-rack_input", binmode: true) if rewindable
        @buffer     = nil
        @eof        = false
      end

      # Retrieves data using the IO#read semantics. If rack input is declared
      # rewindable, writes retrieved content into a Tempfile object so that
      # it can later be re-read.
      def read(length = nil, outbuf = nil)
        data = outbuf.clear if outbuf
        data = @cache.read(length, outbuf) if @cache && !@cache.eof?

        loop do
          remaining_length = length - data.bytesize if data && length

          break if remaining_length == 0

          @buffer = next_chunk or break if @buffer.nil?

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

      # Rewinds the tempfile if rewindable. Otherwise raises Errno::ESPIPE
      # exception, which is what other non-rewindable Ruby IO objects raise.
      def rewind
        raise Errno::ESPIPE if @cache.nil?
        @cache.rewind
      end

      # Deletes the tempfile. The #close method is also part of the Rack
      # specification.
      def close
        @cache.close! if @cache
      end

      private

      # Retrieves the next chunk by calling the block, and marks EOF when nil
      # was returned.
      def next_chunk
        return if @eof
        chunk = @next_chunk.call
        @eof = true if chunk.nil?
        chunk
      end
    end
  end
end
