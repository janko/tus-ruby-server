Feature: Checksum

  Scenario: Correct Upload-Checksum
    Given I've created a file
      """
      Upload-Length: 11
      """
    When I make a PATCH request to the created file
      """
      Tus-Resumable: 1.0.0
      Upload-Offset: 0
      Content-Type: application/offset+octet-stream
      Upload-Checksum: sha1 Kq5sNclPz7QV2+lfQIuc6R7oRu0=

      hello world
      """
    Then I should see response status "204 No Content"
    And I should see response headers
      """
      Upload-Offset: 11
      """

  Scenario: Incorrect Upload-Checksum
    Given I've created a file
      """
      Upload-Length: 11
      """
    When I make a PATCH request to the created file
      """
      Tus-Resumable: 1.0.0
      Upload-Offset: 0
      Content-Type: application/offset+octet-stream
      Upload-Checksum: sha1 foobar

      hello world
      """
    Then I should see response status "460 Checksum Mismatch"
    And I should see "Upload-Checksum value doesn't match generated checksum"

  Scenario: Invalid Upload-Checksum
    Given I've created a file
      """
      Upload-Length: 11
      """
    When I make a PATCH request to the created file
      """
      Tus-Resumable: 1.0.0
      Upload-Offset: 0
      Content-Type: application/offset+octet-stream
      Upload-Checksum: foo bar

      hello world
      """
    Then I should see response status "400 Bad Request"
    And I should see "Invalid Upload-Checksum header"

    Given I've created a file
      """
      Upload-Length: 11
      """
    When I make a PATCH request to the created file
      """
      Tus-Resumable: 1.0.0
      Upload-Offset: 0
      Content-Type: application/offset+octet-stream
      Upload-Checksum: foo bar

      hello world
      """
    Then I should see response status "400 Bad Request"
    And I should see "Invalid Upload-Checksum header"

  Scenario: Too Large Content
    Given I've created a file
      """
      Upload-Length: 5
      """
    When I make a PATCH request to the created file
      """
      Tus-Resumable: 1.0.0
      Upload-Offset: 0
      Content-Type: application/offset+octet-stream
      Upload-Checksum: sha1 Kq5sNclPz7QV2+lfQIuc6R7oRu0=

      hello world
      """
    Then I should see response status "413 Payload Too Large"
    And I should see "Size of this chunk surpasses Upload-Length"
