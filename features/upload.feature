Feature: Upload

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

      hello
      """
    Then I should see response status "403 Forbidden"
    And I should see "Cannot modify completed upload"

  Scenario: Incorrect Upload-Offset
    Given I've created a file
      """
      Upload-Length: 10
      """
    When I make a PATCH request to the created file
      """
      Tus-Resumable: 1.0.0
      Upload-Offset: 5
      Content-Type: application/offset+octet-stream

      hello
      """
    Then I should see response status "409 Conflict"
    And I should see "Upload-Offset header doesn't match current offset"

  Scenario: Invalid Upload-Offset
    Given I've created a file
      """
      Upload-Length: 10
      """

    When I make a PATCH request to the created file
      """
      Tus-Resumable: 1.0.0
      Upload-Offset: foo
      Content-Type: application/offset+octet-stream

      hello
      """
    Then I should see response status "400 Bad Request"
    And I should see "Invalid Upload-Offset header"

    When I make a PATCH request to the created file
      """
      Tus-Resumable: 1.0.0
      Upload-Offset: -1
      Content-Type: application/offset+octet-stream

      hello
      """
    Then I should see response status "400 Bad Request"
    And I should see "Invalid Upload-Offset header"

  Scenario: Missing Upload-Offset
    Given I've created a file
      """
      Upload-Length: 10
      """
    When I make a PATCH request to the created file
      """
      Tus-Resumable: 1.0.0
      Content-Type: application/offset+octet-stream

      hello
      """
    Then I should see response status "400 Bad Request"
    And I should see "Missing Upload-Offset header"

  Scenario: Invalid Content-Type
    Given I've created a file
      """
      Upload-Length: 100
      """
    When I make a PATCH request to the created file
      """
      Tus-Resumable: 1.0.0
      Upload-Offset: 0
      Content-Type: text/plain
      """
    Then I should see response status "415 Unsupported Media type"

  Scenario: Missing Content-Type
    Given I've created a file
      """
      Upload-Length: 100
      """
    When I make a PATCH request to the created file
      """
      Tus-Resumable: 1.0.0
      Upload-Offset: 0
      """
    Then I should see response status "415 Unsupported Media type"

  Scenario: Upload not found
    When I make a PATCH request to /files/unknown
      """
      Tus-Resumable: 1.0.0
      Upload-Offset: 0
      """
    Then I should see response status "404 Not Found"
    And I should see "Upload Not Found"

  Scenario: Missing Tus-Resumable
    Given I've created a file
      """
      Upload-Length: 100
      """
    When I make a PATCH request to the created file
      """
      Upload-Offset: 0
      Content-Type: application/offset+octet-stream
      """
    Then I should see response status "412 Precondition Failed"
