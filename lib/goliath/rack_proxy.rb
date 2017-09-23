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
      rack_app         = self.class.rack_proxy_options.fetch(:rack_app)
      rewindable_input = self.class.rack_proxy_options.fetch(:rewindable_input, true)

      env["rack_proxy.call"] = RackCall.new(rack_app, env, rewindable_input: rewindable_input)
      env["rack_proxy.call"].resume
    end

    # Called on each request body chunk received from the client.
    def on_body(env, data)
      # write data to the input, which will be read by the Rack app
      env["rack_proxy.call"].resume(data)
    end

    # Called at the end of the request (after #response) or on client disconnect.
    def on_close(env)
      # reading the request body has finished, so we close write end of the input
      env["rack_proxy.call"].resume
    end

    # Called after all the data has been received from the client.
    def response(env)
      env["rack_proxy.call"].resume
    end

    private

    class RackCall
      def initialize(app, env, rewindable_input: true)
        @fiber = Fiber.new do
          rack_input = RackInput.new(rewindable: rewindable_input) { Fiber.yield }

          result = app.call env.merge(
            "rack.input"     => rack_input,
            "async.callback" => nil, # prevent Roda/Sinatra from calling EventMachine while streaming the response
          )

          rack_input.close

          result
        end
      end

      def resume(data = nil)
        @result = @fiber.resume(data) if @fiber.alive?
        @result
      end
    end

    # IO-like object that acts as a bidirectional pipe, which returns the data
    # that has been written to it.
    class RackInput
      def initialize(rewindable: true, &next_chunk)
        @next_chunk = next_chunk
        @cache      = Tempfile.new("goliath-rack_input") if rewindable
        @buffer     = nil
        @eof        = false
      end

      # Pops chunks of data from the queue and implements
      # `IO#read(length = nil, outbuf = nil)` semantics.
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

      # Rewinds the cache IO if it's configured, otherwise raises Errno::ESPIPE
      # exception, which mimics the behaviour of caling #rewind on
      # non-rewindable IOs such as pipes, sockets, and ttys.
      def rewind
        raise Errno::ESPIPE if @cache.nil? # raised by other non-rewindable IOs
        @cache.rewind
      end

      # Conforming to the Rack specification.
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
