Feature: Defer Length

  Scenario: Regular amount of data
    When I create a file
      """
      Upload-Defer-Length: 1
      """
    Then I should see response status "201 Created"
    And I should see response headers
      """
      Upload-Defer-Length: 1
      """
    And I should not see "Upload-Length" response header

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
      Upload-Offset: 5
      Upload-Defer-Length: 1
      """
    And I should not see "Upload-Length" response header

    When I make a PATCH request to the created file
      """
      Tus-Resumable: 1.0.0
      Upload-Offset: 5
      Upload-Length: 11
      Content-Type: application/offset+octet-stream

       world
      """
    Then I should see response status "204 No Content"
    And I should see response headers
      """
      Upload-Length: 11
      Upload-Offset: 11
      """
    And I should not see "Upload-Defer-Length" response header

  Scenario: Exceeding maximum size
    Given I've set max size to 10
    And I've created a file
      """
      Upload-Defer-Length: 1
      """

    When I make a PATCH request to the created file
      """
      Tus-Resumable: 1.0.0
      Upload-Offset: 0
      Content-Type: application/offset+octet-stream

      hello world
      """
    Then I should see response status "413 Payload Too Large"
    And I should see "Size of this chunk surpasses Tus-Max-Size"

  Scenario: Providing invalid Upload-Length
    Given I've set max size to 5
    And I've created a file
      """
      Upload-Defer-Length: 1
      """
    When I make a PATCH request to the created file
      """
      Tus-Resumable: 1.0.0
      Upload-Offset: 0
      Upload-Length: 11
      Content-Type: application/offset+octet-stream

      hello world
      """
    Then I should see response status "413 Payload Too Large"
    And I should see "Upload-Length header too large"

  Scenario: Exceeding Upload-Length
    Given I've created a file
      """
      Upload-Defer-Length: 1
      """
    When I make a PATCH request to the created file
      """
      Tus-Resumable: 1.0.0
      Upload-Offset: 0
      Upload-Length: 5
      Content-Type: application/offset+octet-stream

      hello world
      """
    Then I should see response status "413 Payload Too Large"
    And I should see "Size of this chunk surpasses Upload-Length"
