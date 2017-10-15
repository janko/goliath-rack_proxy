# Goliath::RackProxy

Allows you to use [Goliath] as a web server for your Rack app, giving you streaming requests and responses.

## Motivation

While developing [tus-ruby-server], a Rack application that handles large
uploads and large downloads, I wanted to find an appropriate web server to
recommend. I needed a web server that supports **streaming uploads**, allowing
the Rack application to start processing the request while the request body is
still being received, and that way giving it the ability to save whatever data
it received before possible potential request interruption. I also needed
support for **streaming downloads**, sending response body in chunks back to
the client.

The only web server I found that supported all of this was [Unicorn]. However,
Unicorn needs to spawn a whole process for serving each concurrent request,
which isn't the most efficent use of server resources. It's also difficult to
estimate how many workers you need, because once you disable request buffering
in the application server, you become vulnerable to slow clients.

Then I found [Goliath], which I gave me the control I needed for handling
requests. It's built on top of [EventMachine], which uses the reactor pattern
to schedule work efficiently. The most important feature is that long-running
requests won't impact request throughput, as there are no web workers that are
waiting for incoming data.

However, Goliath itself is designed to be used standalone, not in tandem with
another Rack app. So I created `Goliath::RackProxy`, which is a `Goliath::API`
subclass that proxies incoming/outgoing requests/responses to/from the
specified Rack app in a streaming fashion, essentially making it act like a web
server for the Rack app.

## Installation

```rb
gem "goliath-rack_proxy"
```

## Usage

Create a file where you will initialize the Goliath Rack proxy:

```rb
# app.rb
require "goliath/rack_proxy"

class MyGoliathApp < Goliath::RackProxy
  rack_app MyRackApp # provide your #call-able Rack application
end
```

You can then run the server by running that Ruby file:

```sh
$ ruby app.rb
```

Any command-line arguments passed after the file will be forwarded to the
Goliath server (see [list of available options][goliath server options]):

```sh
$ ruby app.rb --port 3000 --stdout
```

You can scale Goliath applications into multiple processes using [Einhorn]:

```sh
$ einhorn -n COUNT -b 127.0.0.1:3000 ruby app.rb --einhorn
```

By default `Goliath::RackProxy` will use a rewindable `rack.input`, which means
the data received from the client will be cached onto disk for the duration of
the request. If you don't need the `rack.input` to be rewindable and want to
save on disk I/O, you can disable caching:

```rb
class MyGoliathApp < Goliath::RackProxy
  rack_app MyRackApp
  rewindable_input false
end
```

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

[Goliath]: https://github.com/postrank-labs/goliath
[EventMachine]: https://github.com/eventmachine/eventmachine
[tus-ruby-server]: https://github.com/janko-m/tus-ruby-server
[Unicorn]: https://github.com/defunkt/unicorn
[goliath server options]: https://github.com/postrank-labs/goliath/wiki/Server
[Einhorn]: https://github.com/stripe/einhorn
