# tus-ruby-server

A Ruby server for the [tus resumable upload protocol]. It implements the core
1.0 protocol, along with the following extensions:

* [`creation`][creation] (and `creation-defer-length`)
* [`concatenation`][concatenation]
* [`checksum`][checksum]
* [`expiration`][expiration]
* [`termination`][termination]

## Installation

```rb
# Gemfile
gem "tus-server", "~> 2.0"
```

## Usage

The gem provides a `Tus::Server` Rack app, which you can mount inside your
main application. If you're using Rails, you can mount it in `config/routes.rb`:

```rb
# config/routes.rb (Rails)
Rails.application.routes.draw do
  mount Tus::Server => "/files"
end
```

Otherwise you can run it in `config.ru`:

```rb
# config.ru (Rack)
require "tus/server"

map "/files" do
  run Tus::Server
end
```

Now you can tell your tus client library (e.g. [tus-js-client]) to use this
endpoint:

```js
// using tus-js-client
new tus.Upload(file, {
  endpoint: "/files",
  chunkSize: 5*1024*1024, // required unless using Goliath
  // ...
})
```

By default uploaded files will be stored in the `data/` directory. After the
upload is complete, you'll probably want to attach the uploaded file to a
database record. [Shrine] is currently the only file attachment library that
integrates well with tus-ruby-server, see [this walkthrough][shrine resumable
walkthrough] that adds resumable uploads from scratch, and for a complete
example you can check out the [demo app][shrine-tus-demo].

### Goliath

Running the tus server alongside your main app using classic web servers like
Puma or Unicorn is probably fine for most cases, however, it does come with a
few gotchas. First, since these web servers don't accept partial requests
(request where the request body hasn't been fully received), the tus client
must be configured to split the upload into multiple requests. Second, since
web workers are tied for the duration of the request, serving uploaded files
through the tus server app could significantly impact request throughput, so
you need to be careful to avoid that.

There is an alternative. [Goliath] is an asychronous web server built on top of
[EventMachine], which supports streaming requests and streaming responses.

* Asynchronous streaming requests allows the tus server to begin saving
  uploaded data while it's still being received. If the request is interrupted,
  the tus server will attempt to save as much of the data that was received so
  far. This means it's not necessary for the tus client to split the upload
  into multiple smaller requests.

* Asynchronous streaming responses allows the tus server to stream large files
  with very small impact to the request throughput.

Since Goliath is web server, to run tus server on it we'll have to run it as a
standalone web app. It's recommended that you use [goliath-rack_proxy] for
running your tus server app:

```rb
# Gemfile
gem "tus-server", "~> 2.0"
gem "goliath-rack_proxy", "~> 1.0"
```
```rb
# tus.rb
require "tus/server"
require "goliath/rack_proxy"

# any additional Tus::Server configuration you want to put in here

class GoliathTusServer < Goliath::RackProxy
  rack_app Tus::Server
  rewindable_input false # set to true if you're using checksums
end
```
```sh
$ ruby tus.rb --stdout # enable logging
```

This will run the tus server app on the root URL; if you want to run it on some
path you can use `Rack::Builder`:

```rb
class GoliathTusServer < Goliath::RackProxy
  rack_app Rack::Builder.new {
    map("/files") { run Tus::Server }
  }
  rewindable_input false # set to true if you're using checksums
end
```

In this case you'll have to configure the tus client to point to the standalone
Goliath app:

```js
// using tus-js-client
new tus.Upload(file, {
  endpoint: "http://localhost:9000/files",
  // ...
})
```

## Storage

### Filesystem

By default `Tus::Server` stores uploaded files in the `data/` directory. You
can configure a different directory:

```rb
require "tus/storage/filesystem"

Tus::Server.opts[:storage] = Tus::Storage::Filesystem.new("public/tus")
```

If the configured directory doesn't exist, it will automatically be created.
By default the UNIX permissions applied will be 0644 for files and 0755 for
directories, but you can set different permissions:

```rb
Tus::Storage::Filesystem.new("data", permissions: 0600, directory_permissions: 0777)
```

One downside of filesystem storage is that it doesn't work by default if you
want to run tus-ruby-server on multiple servers, you'd have to set up a shared
filesystem between the servers. Another downside is that you have to make sure
your servers have enough disk space. Also, if you're using Heroku, you cannot
store files on the filesystem as they won't persist.

All these are reasons why you might store uploaded data on a different storage,
and luckily tus-ruby-server ships with two more storages.

#### Serving files

If your retrieving uploaded files through the download endpoint, by default the
files will be served through the Ruby application. However, that's very
inefficient, as web workers are tied when serving download requests and cannot
serve additional requests for that duration.

Therefore, it's highly recommended to delegate serving uploaded files to your
frontend server (Nginx, Apache). This can be achieved with the
`Rack::Sendfile` middleware, see its [documentation][Rack::Sendfile] to learn
more about how to use it with popular frontend servers.

If you're using Rails, you can enable the `Rack::Sendfile` middleware by
setting the `config.action_dispatch.x_sendfile_header` value accordingly:

```rb
Rails.application.config.action_dispatch.x_sendfile_header = "X-Sendfile" # Apache and lighttpd
# or
Rails.application.config.action_dispatch.x_sendfile_header = "X-Accel-Redirect" # Nginx
```

Otherwise you can add the `Rack::Sendfile` middleware to the stack in
`config.ru`:

```rb
use Rack::Sendfile, "X-Sendfile" # Apache and lighttpd
# or
use Rack::Sendfile, "X-Accel-Redirect" # Nginx
```

### Amazon S3

You can switch to `Tus::Storage::S3` to uploads files to AWS S3 using the
multipart API. For this you'll also need to add the [aws-sdk-s3] gem to your
Gemfile.

```rb
# Gemfile
gem "aws-sdk-s3", "~> 1.2"
```

```rb
require "tus/storage/s3"

# You can omit AWS credentials if you're authenticating in other ways
Tus::Server.opts[:storage] = Tus::Storage::S3.new(
  bucket:            "my-app", # required
  access_key_id:     "abc",
  secret_access_key: "xyz",
  region:            "eu-west-1",
)
```

One thing to note is that S3's multipart API requires each chunk except the
last to be **5MB or larger**, so that is the minimum chunk size that you can
specify on your tus client if you want to use the S3 storage.

If you'll be retrieving uploaded files through the tus server app, it's
recommended to set `Tus::Server.opts[:redirect_download]` to `true`. This will
avoid tus server downloading and serving the file from S3, and instead have the
download endpoint redirect to the direct S3 object URL.

```rb
Tus::Server.opts[:redirect_download] = true
```

You can customize how the S3 object URL is being generated by passing a block
to `:redirect_download`, which will then be evaluated in the context of the
`Tus::Server` instance (which allows accessing the `request` object). See
[`Aws::S3::Object#get`] for the list of options that
`Tus::Storage::S3#file_url` accepts.

```rb
Tus::Server.opts[:redirect_download] = -> (uid, info, **options) do
  storage.file_url(uid, info, response_expires: 10, **options) # link expires after 10 seconds
end
```

If you want to files to be stored in a certain subdirectory, you can specify
a `:prefix` in the storage configuration.

```rb
Tus::Storage::S3.new(prefix: "tus", **options)
```

You can also specify additional options that will be fowarded to
[`Aws::S3::Client#create_multipart_upload`] using `:upload_options`.

```rb
Tus::Storage::S3.new(upload_options: {content_disposition: "attachment"}, **options)
```

All other options will be forwarded to [`Aws::S3::Client#initialize`], so you
can for example change the `:endpoint` to use S3's accelerate host:

```rb
Tus::Storage::S3.new(endpoint: "https://s3-accelerate.amazonaws.com", **options)
```

### MongoDB GridFS

MongoDB has a specification for storing and retrieving large files, called
"[GridFS]". Tus-ruby-server ships with `Tus::Storage::Gridfs` that you can
use, which uses the [Mongo] gem.

```rb
# Gemfile
gem "mongo", "~> 2.3"
```

```rb
require "tus/storage/gridfs"

client = Mongo::Client.new("mongodb://127.0.0.1:27017/mydb")
Tus::Server.opts[:storage] = Tus::Storage::Gridfs.new(client: client)
```

You can change the database prefix (defaults to `fs`):

```rb
Tus::Storage::Gridfs.new(client: client, prefix: "fs_temp")
```

By default MongoDB Gridfs stores files in chunks of 256KB, but you can change
that with the `:chunk_size` option:

```rb
Tus::Storage::Gridfs.new(client: client, chunk_size: 1*1024*1024) # 1 MB
```

Note that if you're using the [concatenation] tus feature with Gridfs, all
partial uploads except the last one are required to fill in their Gridfs
chunks, meaning the length of each partial upload needs to be a multiple of the
`:chunk_size` number.

### Other storages

If none of these storages suit you, you can write your own, you just need to
implement the same public interface:

```rb
def create_file(uid, info = {})            ... end
def concatenate(uid, part_uids, info = {}) ... end
def patch_file(uid, io, info = {})         ... end
def update_info(uid, info)                 ... end
def read_info(uid)                         ... end
def get_file(uid, info = {}, range: nil)   ... end
def file_url(uid, info = {}, **options)    ... end # optional
def delete_file(uid, info = {})            ... end
def expire_files(expiration_date)          ... end
```

## Maximum size

By default the size of files the tus server will accept is unlimited, but you
can configure the maximum file size:

```rb
Tus::Server.opts[:max_size] = 5 * 1024*1024*1024 # 5GB
```

## Expiration

Tus-ruby-server automatically adds expiration dates to each uploaded file, and
refreshes this date on each PATCH request. By default files expire 7 days after
they were last updated, but you can modify `:expiration_time`:

```rb
Tus::Server.opts[:expiration_time] = 2*24*60*60 # 2 days
```

Tus-ruby-server won't automatically delete expired files, but each storage
knows how to expire old files, so you just have to set up a recurring task
that will call `#expire_files`.

```rb
expiration_time = Tus::Server.opts[:expiration_time]
tus_storage     = Tus::Server.opts[:storage]
expiration_date = Time.now.utc - expiration_time

tus_storage.expire_files(expiration_time)
```

## Download

In addition to implementing the tus protocol, tus-ruby-server also comes with a
GET endpoint for downloading the uploaded file, which by default streams the
file from the storage. It supports [Range requests], so you can use the tus
file URL as `src` in `<video>` and `<audio>` HTML tags.

It's highly recommended not to serve files through the app, but offload it to
your frontend server if using disk storage, or if using S3 storage have the
download endpoint redirect to the S3 object URL. See the documentation for the
individual storage for instructions how to set this up.

The endpoint will automatically use the following `Upload-Metadata` values if
they're available:

* `type` -- used to set `Content-Type` response header
* `name` -- used to set `Content-Disposition` response header

The `Content-Disposition` header will be set to "inline" by default, but you
can change it to "attachment" if you want the browser to always force download:

```rb
Tus::Server.opts[:disposition] = "attachment"
```

## Checksum

The following checksum algorithms are supported for the `checksum` extension:

* SHA1
* SHA256
* SHA384
* SHA512
* MD5
* CRC32

## Tests

Run tests with

```sh
$ bundle exec rake test # unit tests
$ bundle exec cucumber  # acceptance tests
```

Set `MONGO=1` environment variable if you want to also run MongoDB tests.

## Inspiration

The tus-ruby-server was inspired by [rubytus].

## License

[MIT](/LICENSE.txt)

[tus resumable upload protocol]: http://tus.io/
[tus-js-client]: https://github.com/tus/tus-js-client
[creation]: http://tus.io/protocols/resumable-upload.html#creation
[concatenation]: http://tus.io/protocols/resumable-upload.html#concatenation
[checksum]: http://tus.io/protocols/resumable-upload.html#checksum
[expiration]: http://tus.io/protocols/resumable-upload.html#expiration
[termination]: http://tus.io/protocols/resumable-upload.html#termination
[GridFS]: https://docs.mongodb.org/v3.0/core/gridfs/
[Mongo]: https://github.com/mongodb/mongo-ruby-driver
[shrine-tus-demo]: https://github.com/shrinerb/shrine-tus-demo
[Shrine]: https://github.com/shrinerb/shrine
[trailing headers]: https://tools.ietf.org/html/rfc7230#section-4.1.2
[rubytus]: https://github.com/picocandy/rubytus
[aws-sdk-s3]: https://github.com/aws/aws-sdk-ruby/tree/master/gems/aws-sdk-s3
[`Aws::S3::Client#initialize`]: http://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/S3/Client.html#initialize-instance_method
[`Aws::S3::Client#create_multipart_upload`]: http://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/S3/Client.html#create_multipart_upload-instance_method
[Range requests]: https://tools.ietf.org/html/rfc7233
[Goliath]: https://github.com/postrank-labs/goliath
[EventMachine]: https://github.com/eventmachine/eventmachine
[goliath-rack_proxy]: https://github.com/janko-m/goliath-rack_proxy
[Rack::Sendfile]: https://www.rubydoc.info/github/rack/rack/master/Rack/Sendfile
[`Aws::S3::Object#get`]: https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/S3/Object.html#get-instance_method
[shrine resumable walkthrough]: https://github.com/shrinerb/shrine/wiki/Adding-Resumable-Uploads
