## HEAD

* Modify tus server to call `Storage#finalize_file` when the last chunk was uploaded

* Don't require length of uploaded chunks to be a multiple of `:chunkSize` in `Tus::Storage::Gridfs`

* Don't infer `:chunkSize` from first uploaded chunk in `Tus::Storage::Gridfs`

* Add `#length` to `Response` objects returned from `Storage#get_file`

## 0.9.1 (2017-03-24)

* Fix `Tus::Storage::S3` not properly supporting the concatenation feature.

## 0.9.0 (2017-03-24)

* Add Amazon S3 storage under `Tus::Storage::S3`.

* Make the checksum feature actually work by generating the checksum correctly.

* Make `Content-Disposition` header on the GET endpoint configurable

* Change `Content-Disposition` header on the GET endpoint from "attachment" to
  "inline"

* Delegate concatenation logic to individual storages, allowing the storages
  to implement it much more efficiently.

* Allow storages to save additional information in the info hash.

* Don't automatically delete expired files, instead require the developer to
  call `Storage#expire_files` in a recurring task.

* Delegate expiration logic to the individual storages, allowing the storages
  to implement it much more efficiently.

* Modify storages to raise `Tus::NotFound` when file wasn't found.

* Add `Tus::Error` which storages can use.

* In `Tus::Storage::Gridfs` require that each uploaded chunk except the last
  one can be distributed into even Mongo chunks.

* Return `403 Forbidden` in the GET endpoint when attempting to download an
  unfinished upload.

* Don't require the client to send `Upload-Length` on the first PATCH request
  when `Upload-Defer-Length` is used, allow the client to send `Upload-Length`
  on any PATCH request.

* Stream file content in the GET endpoint directly from the storage, instead of
  first downloading it, and support `Range` header.

* Update `:length`, `:uploadDate` and `:contentType` fields on the Mongo file
  info documents on each PATCH request in `Tus::Storage::Gridfs`.

* Insert all sub-chunks in a single Mongo operation in `Tus::Storage::Gridfs`.

* Infer Mongo chunk size from the size of the first uploaded chunk.

* Add `:chunk_size` to `Tus::Storage::Gridfs` for hardcoding the chunk size for
  all uploads.

* Avoid reading the whole request body into memory, and modify storages to
  save chunks in a streaming fashion.

## 0.2.0 (2016-11-23)

* Refresh `Upload-Expires` for the file after each PATCH request.

## 0.1.1 (2016-11-21)

* Support Rack 1.x in addition to Rack 2.x.

* Don't return 404 when deleting a non-existing file.

* Return 204 for OPTIONS requests even when the file is missing.

* Make sure that all endpoints that should return no content actually return
  no content.
