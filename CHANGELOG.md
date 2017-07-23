## 1.1.1 (2017-07-23)

* Restore backwards compatibility with MRI 2.1 and MRI 2.2 that was broken in previous release (@janko-m)

## 1.1.0 (2017-07-23)

* Ignore retryable networking errors in `Tus::Storage::S3#patch_file` for resiliency (@janko-m)

* Deprecate `Tus::Server::Goliath` in favour of [goliath-rack_proxy](https://github.com/janko-m/goliath-rack_proxy) (@janko-m)

* Reduce string allocations in MRI 2.3+ with `frozen-string-literal: true` magic comments (@janko-m)

## 1.0.0 (2017-07-17)

* Add Goliath integration (@janko-m)

* [BREAKING] Save data in `"#{uid}"` instead of `"#{uid}.file"` in `Tus::Storage::Filesystem` (@janko-m)

* Modify S3 storage to cache chunks into memory instead of disk, which reduces disk IO (@janko-m)

* [BREAKING] Require each storage to return the number of bytes uploaded in `#patch_file` (@janko-m)

* Make S3 storage upload all received data from `tus-js-client` that doesn't have max chunk size configured (@janko-m)

* Verify that all partial uploads have `Upload-Concat: partial` before concatenation (@janko-m)

* Include CORS and tus response headers in 404 responses (@janko-m)

* Improve streaming on dynamic Rack inputs such as `Unicorn::TeeInput` for S3 and Gridfs storage (@janko-m)

* Terminate HTTP connection to S3 when response is closed (@janko-m)

* Allow `Transfer-Encoding: chunked` to be used, meaning `Content-Length` can be blank (@janko-m)

* Remove newlines from the base64-encoded CRC32 signature (@janko-m)

* Lazily require `digest`, `zlib`, and `base64` standard libraries (@janko-m)

## 0.10.2 (2017-04-19)

* Allow empty metadata values in `Upload-Metadata` header (@lysenkooo)

## 0.10.1 (2017-04-13)

* Fix download endpoint returning incorrect response body in some cases in development (@janko-m)

* Remove `concatenation-unfinished` from list of supported extensions (@janko-m)

## 0.10.0 (2017-03-27)

* Fix invalid `Content-Disposition` header in GET requests to due mutation of `Tus::Server.opts[:disposition]` (@janko-m)

* Make `Response` object from `Tus::Server::S3` also respond to `#close` (@janko-m)

* Don't return `Content-Type` header when there is no content returned (@janko-m)

* Return `Content-Type: text/plain` when returning errors (@janko-m)

* Return `Content-Type: application/octet-stream` by default in the GET endpoint (@janko-m)

* Make UNIX permissions configurable via `:permissions` and `:directory_permissions` in `Tus::Storage::Filesystem` (@janko-m)

* Apply UNIX permissions `0644` for files and `0777` for directories in `Tus::Storage::Filesystem` (@janko-m)

* Fix `creation-defer-length` feature not working with unlimited upload size (@janko-m)

* Make the filesize of accepted uploads unlimited by default (@janko-m)

* Modify tus server to call `Storage#finalize_file` when the last chunk was uploaded (@janko-m)

* Don't require length of uploaded chunks to be a multiple of `:chunkSize` in `Tus::Storage::Gridfs` (@janko-m)

* Don't infer `:chunkSize` from first uploaded chunk in `Tus::Storage::Gridfs` (@janko-m)

* Add `#length` to `Response` objects returned from `Storage#get_file` (@janko-m)

## 0.9.1 (2017-03-24)

* Fix `Tus::Storage::S3` not properly supporting the concatenation feature (@janko-m)

## 0.9.0 (2017-03-24)

* Add Amazon S3 storage under `Tus::Storage::S3` (@janko-m)

* Make the checksum feature actually work by generating the checksum correctly (@janko-m)

* Make `Content-Disposition` header on the GET endpoint configurable (@janko-m)

* Change `Content-Disposition` header on the GET endpoint from "attachment" to "inline" (@janko-m)

* Delegate concatenation logic to individual storages, allowing the storages to implement it much more efficiently (@janko-m)

* Allow storages to save additional information in the info hash (@janko-m)

* Don't automatically delete expired files, instead require the developer to call `Storage#expire_files` in a recurring task (@janko-m)

* Delegate expiration logic to the individual storages, allowing the storages to implement it much more efficiently (@janko-m)

* Modify storages to raise `Tus::NotFound` when file wasn't found (@janko-m)

* Add `Tus::Error` which storages can use (@janko-m)

* In `Tus::Storage::Gridfs` require that each uploaded chunk except the last one can be distributed into even Mongo chunks (@janko-m)

* Return `403 Forbidden` in the GET endpoint when attempting to download an unfinished upload (@janko-m)

* Allow client to send `Upload-Length` on any PATCH request when `Upload-Defer-Length` is used (@janko-m)

* Support `Range` requests in the GET endpoint (@janko-m)

* Stream file content in the GET endpoint directly from the storage (@janko-m)

* Update `:length`, `:uploadDate` and `:contentType` Mongo fields on each PATCH request (@janko-m)

* Insert all sub-chunks in a single Mongo operation in `Tus::Storage::Gridfs` (@janko-m)

* Infer Mongo chunk size from the size of the first uploaded chunk (@janko-m)

* Add `:chunk_size` option to `Tus::Storage::Gridfs` (@janko-m)

* Avoid reading the whole request body into memory by doing streaming uploads (@janko-m)

## 0.2.0 (2016-11-23)

* Refresh `Upload-Expires` for the file after each PATCH request (@janko-m)

## 0.1.1 (2016-11-21)

* Support Rack 1.x in addition to Rack 2.x (@janko-m)

* Don't return 404 when deleting a non-existing file (@janko-m)

* Return 204 for OPTIONS requests even when the file is missing (@janko-m)

* Make sure that none of the "empty status codes" return content (@janko-m)
