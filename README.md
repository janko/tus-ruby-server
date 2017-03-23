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

You can run the `Tus::Server` in your `config.ru`:

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

After upload is complete, you'll probably want to attach the uploaded files to
database records. [Shrine] is one file attachment library that supports this,
see [shrine-tus-demo] on how you can integrate the two.

Tus-ruby-server accepts various configuration options via `Tus::Server.opts`,
and it's probably best to modify that before `run Tus::Server`.

### Storage

By default `Tus::Server` saves partial and complete files on the filesystem,
inside the `data/` directory. You can easily change the directory:

```rb
Tus::Server.opts[:storage] = Tus::Storage::Filesystem.new("public/cache")
```

The downside of storing files on the filesystem is that it isn't distributed,
so for resumable uploads to work you have to host the tus application on a
single server.

However, tus-ruby-server also ships with MongoDB [GridFS] storage, which among
other things is convenient for a multi-server setup. It requires the [Mongo]
gem:

```rb
gem "mongo"
```

```rb
require "tus/storage/gridfs"

client = Mongo::Client.new("mongodb://127.0.0.1:27017/mydb")
Tus::Server.opts[:storage] = Tus::Storage::Gridfs.new(client: client)
```

You can also write your own storage, you just need to implement the same
public interface that `Tus::Storage::Filesystem` and `Tus::Storage::Gridfs` do.

### Maximum size

By default the maximum size for an uploaded file is 1GB, but you can change
that:

```rb
Tus::Server.opts[:max_size] = 5 * 1024*1024*1024 # 5GB
Tus::Server.opts[:max_size] = nil                # no limit
```

### Expiration

Tus-ruby-server automatically adds expiration dates to each uploaded file, and
updates this date on each PATCH request. By default files expire 7 days after
they were last updated, but that can be changed:

```rb
Tus::Server.opts[:expiration_time] = 2*24*60*60 # 2 days
```

Storages know how to delete files that have reached their expiration date,
but tus-ruby-server won't automatically call storages to expire those files,
you will have to set up a recurring task to do that.

```rb
expiration_date = Time.now.utc - Tus::Server.opts[:expiration_time]
Tus::Server.opts[:storage].expire_files(expiration_date)
```

### Checksum

The following checksum algorithms are supported for the `checksum` extension:

* SHA1
* SHA256
* SHA384
* SHA512
* MD5
* CRC32

### Download

Tus-ruby-server offers an endpoint for downloading the uploaded file, which
will automatically use the following `Upload-Metadata` values if they're
available:

* `content_type` -- for setting the `Content-Type` header
* `filename` -- for setting the `Content-Disposition` header

The `Content-Disposition` header will be set to "inline" by default, but you
can change it to "attachment" if you want the browser to always force download:

```rb
Tus::Server.opts[:disposition] = "attachment"
```

## Limitations

Since tus-ruby-server is built using a Rack-based web framework (Roda), if a
PATCH request gets interrupted, none of the received data will be stored. It's
recommended to configure your client tus library not to use a single PATCH
request for large files, but rather to split it into multiple chunks. You can
do that for [tus-js-client] by specifying a maximum chunk size:

```js
new tus.Upload(file, {
  endpoint: "http://localhost:9292/files",
  chunkSize: 15*1024*1024, // 15 MB
  // ...
})
```

Tus-server also currently doesn't support the `checksum-trailer` extension,
which would allow sending the checksum header *after* the data has been sent,
using [trailing headers].

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
