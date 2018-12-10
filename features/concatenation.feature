Feature: Concatenation

  Scenario: Creating partial upload
    When I make a POST request to "/files"
      """
      Tus-Resumable: 1.0.0
      Upload-Length: 5
      Upload-Concat: partial
      """
    Then I should see response status "201 Created"
    And I should see response headers
      """
      Upload-Concat: partial
      """

  Scenario: Creating final upload from partial uploads
    Given a file
      """
      Upload-Length: 5
      Upload-Concat: partial

      hello
      """
    And a file
      """
      Upload-Length: 6
      Upload-Concat: partial

       world
      """
    When I send a concatenation request for the created files
    Then I should see response status "201 Created"
    And I should see response headers
      """
      Upload-Length: 11
      Upload-Offset: 11
      """
    And "Upload-Concat" response header should match "^final;http://example.com/files/\w+ http://example.com/files/\w+$"

    When I make a HEAD request to the concatenated file
      """
      Tus-Resumable: 1.0.0
      """
    Then I should see response status "204 No Content"
    And I should see response headers
      """
      Upload-Length: 11
      Upload-Offset: 11
      """
    And "Upload-Concat" response header should match "^final;http://example.com/files/\w+ http://example.com/files/\w+$"

    When I make a GET request to the concatenated file
      """
      """
    Then I should see response status "200 OK"
    And I should see "hello world"

  Scenario: Creating final upload from non-partial uploads
    Given a file
      """
      Upload-Length: 5

      hello
      """
    And a file
      """
      Upload-Length: 6

       world
      """
    When I send a concatenation request for the created files
    Then I should see response status "400 Bad Request"
    And I should see "One or more uploads were not partial"

  Scenario: Creating final upload from non-existing uploads
    Given a file
      """
      Upload-Length: 5
      Upload-Concat: partial

      hello
      """
    And a file
      """
      Upload-Length: 6
      Upload-Concat: partial

       world
      """
    When I make a DELETE request to the created file
      """
      Tus-Resumable: 1.0.0
      """
    And I send a concatenation request for the created files
    Then I should see response status "400 Bad Request"
    And I should see "One or more partial uploads were not found"

  Scenario: Concatenation within Tus-Max-Size
    Given I've set max size to 12
    And a file
      """
      Upload-Length: 5
      Upload-Concat: partial

      hello
      """
    And a file
      """
      Upload-Length: 6
      Upload-Concat: partial

       world
      """
    When I send a concatenation request for the created files
    Then I should see response status "201 Created"
    And I should see response headers
      """
      Upload-Length: 11
      Upload-Offset: 11
      """

  Scenario: Concatenation exceeding Tus-Max-Size
    Given I've set max size to 10
    And a file
      """
      Upload-Length: 5
      Upload-Concat: partial

      hello
      """
    And a file
      """
      Upload-Length: 6
      Upload-Concat: partial

       world
      """
    When I send a concatenation request for the created files
    Then I should see response status "400 Bad Request"
    And I should see "The sum of partial upload lengths exceed Tus-Max-Size"

  Scenario: Invalid Upload-Concat
    When I make a POST request to "/files"
      """
      Tus-Resumable: 1.0.0
      Upload-Length: 5
      Upload-Concat: foo
      """
    Then I should see response status "400 Bad Request"
    And I should see "Invalid Upload-Concat header"
