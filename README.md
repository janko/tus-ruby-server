# tus-ruby-server

A Ruby server for the [tus resumable upload protocol]. It implements the core
1.0 protocol, along with the following extensions:

* [`creation`][creation] (and `creation-defer-length`)
* [`concatenation`][concatenation] (and `concatenation-unfinished`)
* [`checksum`][checksum]
* [`expiration`][expiration]
* [`termination`][termination]

## Installation

```rb
gem "tus-server"
```

## Usage

Tus-ruby-server provides a `Tus::Server` Roda app, which you can run in your
`config.ru`. That way you can run `Tus::Server` both as a standalone app or as
part of your main app (though it's recommended to run it as a standalone app,
as explained in the "Performance considerations" section of this README).

```rb
# config.ru
require "tus/server"

map "/files" do
  run Tus::Server
end

run YourApp
```

Now you can tell your tus client library (e.g. [tus-js-client]) to use this
endpoint:

```js
// using tus-js-client
new tus.Upload(file, {
  endpoint: "http://localhost:9292/files",
  chunkSize: 5*1024*1024, // 5MB
  // ...
})
```

After the upload is complete, you'll probably want to attach the uploaded file
to a database record. [Shrine] is one file attachment library that integrates
nicely with tus-ruby-server, see [shrine-tus-demo] for an example integration.

## Storage

### Filesystem

By default `Tus::Server` stores uploaded files to disk, in the `data/`
directory. You can configure a different directory:

```rb
require "tus/storage/filesystem"

Tus::Server.opts[:storage] = Tus::Storage::Filesystem.new("public/cache")
```

One downside of filesystem storage is that by default it doesn't work if you
want to run tus-ruby-servers on multiple servers, you'd have to set up a shared
filesystem between the servers. Another downside is that you have to make sure
your servers have enough disk space. Also, if you're using Heroku, you cannot
store files on the filesystem as they won't persist.

All these are reasons why you might store uploaded data on a different storage,
and luckily tus-ruby-server ships with two more storages.

### MongoDB GridFS

MongoDB has a specification for storing and retrieving large files, called
"[GridFS]". Tus-ruby-server ships with `Tus::Storage::Gridfs` that you can
use, which uses the [Mongo] gem.

```rb
gem "mongo", ">= 2.2.2", "< 3"
```

```rb
require "tus/storage/gridfs"

client = Mongo::Client.new("mongodb://127.0.0.1:27017/mydb")
Tus::Server.opts[:storage] = Tus::Storage::Gridfs.new(client: client)
```

The Gridfs specification requires that all chunks are of equal size, except the
last chunk. `Tus::Storage::Gridfs` will by default automatically make the
Gridfs chunk size equal to the size of the first uploaded chunk. This means
that all of the uploaded chunks need to be of equal size (except the last
chunk).

If you don't want the Gridfs chunk size to be equal to the size of the uploaded
chunks, you can hardcode the chunk size that will be used for all uploads.

```rb
Tus::Storage::Gridfs.new(client: client, chunk_size: 256*1024) # 256 KB
```

Just note that in this case the size of each uploaded chunk (except the last
one) needs to be a multiple of the `:chunk_size`.

### Amazon S3

Amazon S3 is probably one of the most popular services for storing files, and
tus-ruby-server ships with `Tus::Storage::S3` which utilizes S3's multipart API
to upload files, and depends on the [aws-sdk] gem.

```rb
gem "aws-sdk", "~> 2.1"
```

```rb
require "tus/storage/s3"

Tus::Server.opts[:storage] = Tus::Storage::S3.new(
  access_key_id:     "abc",
  secret_access_key: "xyz",
  region:            "eu-west-1",
  bucket:            "my-app",
)
```

It might seem at first that using a remote storage like Amazon S3 will slow
down the overall upload, but the time it takes for the client to upload the
file to the Rack app is in general *much* longer than the time for the server
to upload that chunk to S3, because of the differences in the Internet
connection speed between the user's computer and server.

One thing to note is that S3's multipart API requires each chunk except the last
one to be 5MB or larger, so that is the minimum chunk size that you can specify
on your tus client if you want to use the S3 storage.

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
def delete_file(uid, info = {})            ... end
def expire_files(expiration_date)          ... end
```

## Maximum size

By default the maximum size for an uploaded file is 1GB, but you can change
that:

```rb
Tus::Server.opts[:max_size] = 5 * 1024*1024*1024 # 5GB
Tus::Server.opts[:max_size] = nil                # no limit
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
expiration_date = Time.now.utc - Tus::Server.opts[:expiration_time]
Tus::Server.opts[:storage].expire_files(expiration_date)
```

## Download

In addition to implementing the tus protocol, tus-ruby-server also comes with a
GET endpoint for downloading the uploaded file, which streams the file directly
from the storage.

The endpoint will automatically use the following `Upload-Metadata` values if
they're available:

* `content_type` -- used in the `Content-Type` response header
* `filename` -- used in the `Content-Disposition` response header

The `Content-Disposition` header will be set to "inline" by default, but you
can change it to "attachment" if you want the browser to always force download:

```rb
Tus::Server.opts[:disposition] = "attachment"
```

The download endpoint supports [Range requests], so you can use the tus
file URL as `src` in `<video>` and `<audio>` HTML tags.

## Checksum

The following checksum algorithms are supported for the `checksum` extension:

* SHA1
* SHA256
* SHA384
* SHA512
* MD5
* CRC32

## Performance considerations

### Buffering

When handling file uploads it's important not be be vulnerable to slow-write
clients. That means you need to make sure that your web/application server
buffers the request body locally before handing the request to the request
worker.

If the request body is not buffered and is read directly from the socket when
it has already reached your Rack application, your application throughput will
be severly impacted, because the workers will spend majority of their time
waiting for request body to be read from the socket, and in that time they
won't be able to serve new requests.

Puma will automatically buffer the whole request body in a Tempfile, before
fowarding the request to your Rack app. Unicorn and Passenger will not do that,
so it's highly recommended to put a frontend server like Nginx in front of
those web servers, and configure it to buffer the request body.

### Chunking

The tus protocol specifies

> The Server SHOULD always attempt to store as much of the received data as possible.

The tus-ruby-server Rack application supports saving partial data for if the
PATCH request gets interrupted before all data has been sent, but I'm not aware
of any Rack-compliant web server that will forward interrupted requests to the
Rack app.

This means that for resumable upload to be possible with tus-ruby-server in
general, the file must be uploaded in multiple chunks; the client shouldn't
rely that server will store any data if the PATCH request was interrupted.

```js
// using tus-js-client
new tus.Upload(file, {
  endpoint: "http://localhost:9292/files",
  chunkSize: 5*1024*1024, // required option
  // ...
})
```

### Downloading

Tus-ruby-server has a download endpoint which streams the uploaded file to the
client. Unfortunately, with most classic web servers this endpoint will be
vulnerable to slow-read clients, because the worker is only done once the whole
response body has been received by the client. Web servers that are not
vulnerable to slow-read clients include [Goliath]/[Thin] ([EventMachine]) and
[Reel] ([Celluloid::IO]).

So, depending on your requirements, you might want to avoid displaying the
uploaded file in the browser (making the user download the file directly from
the tus server), until it has been moved to a permanent storage. You might also
want to consider copying finished uploads to permanent storage directly from
the underlying tus storage, instead of downloading it through the app.

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
[shrine-tus-demo]: https://github.com/janko-m/shrine-tus-demo
[Shrine]: https://github.com/janko-m/shrine
[trailing headers]: https://tools.ietf.org/html/rfc7230#section-4.1.2
[rubytus]: https://github.com/picocandy/rubytus
[aws-sdk]: https://github.com/aws/aws-sdk-ruby
[`Aws::S3::Client#initialize`]: http://docs.aws.amazon.com/sdkforruby/api/Aws/S3/Client.html#initialize-instance_method
[`Aws::S3::Client#create_multipart_upload`]: http://docs.aws.amazon.com/sdkforruby/api/Aws/S3/Client.html#create_multipart_upload-instance_method
[Range requests]: https://tools.ietf.org/html/rfc7233
[EventMachine]: https://github.com/eventmachine/eventmachine
[Reel]: https://github.com/celluloid/reel
[Goliath]: https://github.com/postrank-labs/goliath
[Thin]: https://github.com/macournoyer/thin
[Celluloid::IO]: https://github.com/celluloid/celluloid-io
