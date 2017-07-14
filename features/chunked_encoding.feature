Feature: Chunked Encoding

  Scenario: Appending data
    Given I've created a file
      """
      Upload-Length: 11
      """

    When I make a PATCH request to the created file
      """
      Tus-Resumable: 1.0.0
      Upload-Offset: 0
      Content-Type: application/offset+octet-stream
      Transfer-Encoding: chunked

      hello
      """
    Then I should see response status "204 No Content"
    And I should see response headers
      """
      Tus-Resumable: 1.0.0
      Upload-Length: 11
      Upload-Offset: 5
      """

    When I make a PATCH request to the created file
      """
      Tus-Resumable: 1.0.0
      Upload-Offset: 5
      Content-Type: application/offset+octet-stream
      Transfer-Encoding: chunked

       world
      """
    Then I should see response status "204 No Content"
    And I should see response headers
      """
      Tus-Resumable: 1.0.0
      Upload-Length: 11
      Upload-Offset: 11
      """

  Scenario: Appending with too large chunk
    Given I've created a file
      """
      Upload-Length: 5
      """
    When I make a PATCH request to the created file
      """
      Tus-Resumable: 1.0.0
      Upload-Offset: 0
      Content-Type: application/offset+octet-stream
      Transfer-Encoding: chunked

      hello world
      """
    Then I should see response status "413 Payload Too Large"
    And I should see "Size of this chunk surpasses Upload-Length"

  Scenario: Appending to already completed upload
    Given I've created a file
      """
      Upload-Length: 0
      """
    When I make a PATCH request to the created file
      """
      Tus-Resumable: 1.0.0
      Upload-Offset: 0
      Content-Type: application/offset+octet-stream
      Transfer-Encoding: chunked

      hello
      """
    Then I should see response status "403 Forbidden"
    And I should see "Cannot modify completed upload"

