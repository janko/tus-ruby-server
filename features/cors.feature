Feature: CORS

  Scenario: Preflight requests
    When I make an OPTIONS request to "/files"
      """
      Tus-Resumable: 1.0.0
      Origin: tus-server.org
      """
    Then I should see response headers
      """
      Access-Control-Allow-Origin: tus-server.org
      Access-Control-Allow-Methods: POST, GET, HEAD, PATCH, DELETE, OPTIONS
      Access-Control-Allow-Headers: Origin, X-Requested-With, Content-Type, Upload-Length, Upload-Offset, Tus-Resumable, Upload-Metadata
      Access-Control-Max-Age: 86400
      """

  Scenario: Regular requests
    When I make a HEAD request to "/files/unknown"
      """
      Tus-Resumable: 1.0.0
      Origin: tus-server.org
      """
    Then I should see response headers
      """
      Access-Control-Allow-Origin: tus-server.org
      Access-Control-Expose-Headers: Upload-Offset, Location, Upload-Length, Tus-Version, Tus-Resumable, Tus-Max-Size, Tus-Extension, Upload-Metadata
      """
