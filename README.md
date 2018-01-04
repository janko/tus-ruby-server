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
gem "tus-server"
```

## Usage

Tus-ruby-server provides a `Tus::Server` Roda app, which you can run in your
`config.ru`. That way you can run `Tus::Server` both as a standalone app or as
part of your main app.

```rb
# config.ru
require "tus/server"

map "/files" do
  run Tus::Server
end

run YourApp
```

While this is the most flexible option, it's not optimal in terms of
performance; see the [Goliath](#goliath) section for an alternative approach.

Now you can tell your tus client library (e.g. [tus-js-client]) to use this
endpoint:

```js
// using tus-js-client
new tus.Upload(file, {
  endpoint: "http://localhost:9292/files",
  chunkSize: 5*1024*1024, // required unless using Goliath or Unicorn
  // ...
})
```

After the upload is complete, you'll probably want to attach the uploaded file
to a database record. [Shrine] is one file attachment library that integrates
nicely with tus-ruby-server, see [shrine-tus-demo] for an example integration.

### Goliath

Among all the existing Ruby web servers, [Goliath] is probably the ideal one to
run tus-ruby-server on. It's built on top of [EventMachine], making it
asynchronous both in reading the request body and writing to the response body.
Goliath also allows tus-ruby-server to handle interrupted requests, by saving
data that has been uploaded until the interruption. This means that with
Goliath it's **not** mandatory for client to chunk the upload into multiple
requests in order to achieve resumable upload (which would be the case for most
other web servers).

It's recommended that you use [goliath-rack_proxy] for running your tus server
app:

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
    map "/files" do
      run Tus::Server
    end
  }
  rewindable_input false # set to true if you're using checksums
end
```

### Unicorn

Like Goliath, Unicorn also support streaming uploads, and tus-ruby-server knows
how to automatically recover from `Unicorn::ClientShutdown` exceptions during
upload, storing data that it has received up until that point. Just note that
in order to achieve streaming uploads, Nginx should be configured **not** to
buffer incoming requests, and to disable worker timeout to enable long running
upload requests:

```rb
timeout 60*60*24*30 # set worker timeout to 30 days
```

But it's also fine to have Nginx buffer requests, just note that in this case
Nginx won't forward incomplete upload requests to tus-ruby-server, so in order
for resumable upload to be possible the client needs to send data in multiple
upload requests (which can then be retried individually).

Unless you're using the "checksum" tus feature, you might want to consider
disabling rewindability of request body, to prevent Unicorn from additionally
caching received data onto the disk (since that's not necessary unless request
body needs to be rewinded).

```rb
# config/unicorn.rb
# ...

rewindable_input false
```

### Other web servers

It's perfectly feasible to run tus-ruby-server on web servers other than
Goliath or Unicorn (even necessary if you want to run it inside another app).
Just keep in mind that most other web servers don't support request streaming,
which means that tus-ruby-server will be able to start processing upload
requess only once the whole request body has been received. Additionally,
incomplete upload requests won't be forwarded to tus-ruby-server, so in order
for resumable upload to be possible the client needs to send data in multiple
upload requests (which can then be retried individually).

## Storage

### Filesystem

By default `Tus::Server` stores uploaded files to disk, in the `data/`
directory. You can configure a different directory:

```rb
require "tus/storage/filesystem"

Tus::Server.opts[:storage] = Tus::Storage::Filesystem.new("public/cache")
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

### Amazon S3

Amazon S3 is probably one of the most popular services for storing files, and
tus-ruby-server ships with `Tus::Storage::S3` which utilizes S3's multipart API
to upload files, and depends on the [aws-sdk-s3] gem.

```rb
gem "aws-sdk-s3", "~> 1.2"
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

One thing to note is that S3's multipart API requires each chunk except the
last to be **5MB or larger**, so that is the minimum chunk size that you can
specify on your tus client if you want to use the S3 storage.

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
GET endpoint for downloading the uploaded file, which streams the file from the
storage into the response body.

The endpoint will automatically use the following `Upload-Metadata` values if
they're available:

* `type` -- used in the `Content-Type` response header
* `name` -- used in the `Content-Disposition` response header

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

## Tests

Run tests with

```sh
$ bundle exec rake test # unit tests
$ bundle exec cucumber  # acceptance tests
```

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
[aws-sdk-s3]: https://github.com/aws/aws-sdk-ruby/tree/master/gems/aws-sdk-s3
[`Aws::S3::Client#initialize`]: http://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/S3/Client.html#initialize-instance_method
[`Aws::S3::Client#create_multipart_upload`]: http://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/S3/Client.html#create_multipart_upload-instance_method
[Range requests]: https://tools.ietf.org/html/rfc7233
[Goliath]: https://github.com/postrank-labs/goliath
[EventMachine]: https://github.com/eventmachine/eventmachine
[goliath-rack_proxy]: https://github.com/janko-m/goliath-rack_proxy
