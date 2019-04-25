## HEAD

* Add `ETag` header to download endpoint to prevent `Rack::ETag` buffering file content (@janko)

* Take `:prefix` into account in `Tus::Storage::S3#expire_files` (@janko)

## 2.2.1 (2018-12-19)

* Use `content_disposition` gem to generate `Content-Disposition` in download endpoint (@janko)

## 2.2.0 (2018-12-02)

* Add `before_create`, `after_create`, `after_finish`, and `after_terminate` hooks (@janko)

* Rename `Tus::Info#concatenation?` to `Tus::Info#final?` (@janko)

* Use `Storage#concurrency` for parallelized retrieval of partial uploads in `Upload-Concat` validation (@janko)

* Replace `:thread_count` with `:concurrency` in S3 storage (@janko)

* Validate that sum of partial uploads doesn't exceed `Tus-Max-Size` on concatenation (@janko)

* Drop MRI 2.2 support (@janko)

* Accept absolute URLs of partial uploads when creating a final upload (@janko)

## 2.1.2 (2018-10-21)

* Make tus-ruby-server fully work with non-rewindable Rack input (@janko)

## 2.1.1 (2018-05-26)

* Rename `:download_url` option to `:redirect_download` (@janko)

## 2.1.0 (2018-05-15)

* Add `:download_url` server option for redirecting to a download URL (@janko)

* Allow application servers to serve files stored on disk via the `Rack::Sendfile` middleware (@janko)

* Reject `Upload-Metadata` which contains key-value pairs separated by spaces (@janko)

* Don't overwite info file if it already exists in `Tus::Storage::FileSystem` (@janko)

## 2.0.2 (2017-12-24)

* Handle `name` and `type` metadata for Uppy compatibility (@janko)

## 2.0.1 (2017-11-13)

* Add back support for Roda 2.x (@janko)

## 2.0.0 (2017-11-13)

* Upgrade to Roda 3 (@janko)

* Remove deprecated support for aws-sdk 2.x in `Tus::Storage::S3` (@janko)

* Drop official support for MRI 2.1 (@janko)

* Add generic `Tus::Response` class that storages can use (@janko)

* Remove `Tus::Response#length` (@janko)

* Remove deprecated Goliath integration (@janko)

* Return `400 Bad Request` instead of `404 Not Found` when some partial uploads are missing in a concatenation request (@janko)

* Use Rack directly instead of Roda's `streaming` plugin for downloding (@janko)

## 1.2.1 (2017-11-05)

* Improve communication when handling `aws-sdk 2.x` fallback in `Tus::Storage::S3` (@janko)

## 1.2.0 (2017-09-18)

* Deprecate `aws-sdk` 2.x in favour of the new `aws-sdk-s3` gem (@janko)

## 1.1.3 (2017-09-17)

* Return `Accept-Ranges: bytes` response header in download endpoint (@janko)

## 1.1.2 (2017-09-12)

* Add support for the new `aws-sdk-s3` gem (@janko)

## 1.1.1 (2017-07-23)

* Restore backwards compatibility with MRI 2.1 and MRI 2.2 that was broken in previous release (@janko)

## 1.1.0 (2017-07-23)

* Ignore retryable networking errors in `Tus::Storage::S3#patch_file` for resiliency (@janko)

* Deprecate `Tus::Server::Goliath` in favour of [goliath-rack_proxy](https://github.com/janko/goliath-rack_proxy) (@janko)

* Reduce string allocations in MRI 2.3+ with `frozen-string-literal: true` magic comments (@janko)

## 1.0.0 (2017-07-17)

* Add Goliath integration (@janko)

* [BREAKING] Save data in `"#{uid}"` instead of `"#{uid}.file"` in `Tus::Storage::Filesystem` (@janko)

* Modify S3 storage to cache chunks into memory instead of disk, which reduces disk IO (@janko)

* [BREAKING] Require each storage to return the number of bytes uploaded in `#patch_file` (@janko)

* Make S3 storage upload all received data from `tus-js-client` that doesn't have max chunk size configured (@janko)

* Verify that all partial uploads have `Upload-Concat: partial` before concatenation (@janko)

* Include CORS and tus response headers in 404 responses (@janko)

* Improve streaming on dynamic Rack inputs such as `Unicorn::TeeInput` for S3 and Gridfs storage (@janko)

* Terminate HTTP connection to S3 when response is closed (@janko)

* Allow `Transfer-Encoding: chunked` to be used, meaning `Content-Length` can be blank (@janko)

* Remove newlines from the base64-encoded CRC32 signature (@janko)

* Lazily require `digest`, `zlib`, and `base64` standard libraries (@janko)

## 0.10.2 (2017-04-19)

* Allow empty metadata values in `Upload-Metadata` header (@lysenkooo)

## 0.10.1 (2017-04-13)

* Fix download endpoint returning incorrect response body in some cases in development (@janko)

* Remove `concatenation-unfinished` from list of supported extensions (@janko)

## 0.10.0 (2017-03-27)

* Fix invalid `Content-Disposition` header in GET requests to due mutation of `Tus::Server.opts[:disposition]` (@janko)

* Make `Response` object from `Tus::Server::S3` also respond to `#close` (@janko)

* Don't return `Content-Type` header when there is no content returned (@janko)

* Return `Content-Type: text/plain` when returning errors (@janko)

* Return `Content-Type: application/octet-stream` by default in the GET endpoint (@janko)

* Make UNIX permissions configurable via `:permissions` and `:directory_permissions` in `Tus::Storage::Filesystem` (@janko)

* Apply UNIX permissions `0644` for files and `0777` for directories in `Tus::Storage::Filesystem` (@janko)

* Fix `creation-defer-length` feature not working with unlimited upload size (@janko)

* Make the filesize of accepted uploads unlimited by default (@janko)

* Modify tus server to call `Storage#finalize_file` when the last chunk was uploaded (@janko)

* Don't require length of uploaded chunks to be a multiple of `:chunkSize` in `Tus::Storage::Gridfs` (@janko)

* Don't infer `:chunkSize` from first uploaded chunk in `Tus::Storage::Gridfs` (@janko)

* Add `#length` to `Response` objects returned from `Storage#get_file` (@janko)

## 0.9.1 (2017-03-24)

* Fix `Tus::Storage::S3` not properly supporting the concatenation feature (@janko)

## 0.9.0 (2017-03-24)

* Add Amazon S3 storage under `Tus::Storage::S3` (@janko)

* Make the checksum feature actually work by generating the checksum correctly (@janko)

* Make `Content-Disposition` header on the GET endpoint configurable (@janko)

* Change `Content-Disposition` header on the GET endpoint from "attachment" to "inline" (@janko)

* Delegate concatenation logic to individual storages, allowing the storages to implement it much more efficiently (@janko)

* Allow storages to save additional information in the info hash (@janko)

* Don't automatically delete expired files, instead require the developer to call `Storage#expire_files` in a recurring task (@janko)

* Delegate expiration logic to the individual storages, allowing the storages to implement it much more efficiently (@janko)

* Modify storages to raise `Tus::NotFound` when file wasn't found (@janko)

* Add `Tus::Error` which storages can use (@janko)

* In `Tus::Storage::Gridfs` require that each uploaded chunk except the last one can be distributed into even Mongo chunks (@janko)

* Return `403 Forbidden` in the GET endpoint when attempting to download an unfinished upload (@janko)

* Allow client to send `Upload-Length` on any PATCH request when `Upload-Defer-Length` is used (@janko)

* Support `Range` requests in the GET endpoint (@janko)

* Stream file content in the GET endpoint directly from the storage (@janko)

* Update `:length`, `:uploadDate` and `:contentType` Mongo fields on each PATCH request (@janko)

* Insert all sub-chunks in a single Mongo operation in `Tus::Storage::Gridfs` (@janko)

* Infer Mongo chunk size from the size of the first uploaded chunk (@janko)

* Add `:chunk_size` option to `Tus::Storage::Gridfs` (@janko)

* Avoid reading the whole request body into memory by doing streaming uploads (@janko)

## 0.2.0 (2016-11-23)

* Refresh `Upload-Expires` for the file after each PATCH request (@janko)

## 0.1.1 (2016-11-21)

* Support Rack 1.x in addition to Rack 2.x (@janko)

* Don't return 404 when deleting a non-existing file (@janko)

* Return 204 for OPTIONS requests even when the file is missing (@janko)

* Make sure that none of the "empty status codes" return content (@janko)
