Feature: Download

  Scenario: Finished upload
    Given a file
      """
      Upload-Length: 11

      hello world
      """
    When I make a GET request to the created file
      """
      """
    Then I should see response status "200 OK"
    And I should see response headers
      """
      Content-Length: 11
      """
    And I should see "hello world"

  Scenario: Content-Disposition
    Given a file
      """
      Upload-Length: 11

      hello world
      """
    When I make a GET request to the created file
      """
      """
    And I should see response headers
      """
      Content-Disposition: inline
      """

    Given I've set disposition to "attachment"
    When I make a GET request to the created file
      """
      """
    And I should see response headers
      """
      Content-Disposition: attachment
      """

  Scenario: Content-Type
    Given a file
      """
      Upload-Length: 11

      hello world
      """
    When I make a GET request to the created file
      """
      """
    And I should see response headers
      """
      Content-Type: application/octet-stream
      """

  Scenario: Ranged request
    Given a file
      """
      Upload-Length: 11

      hello world
      """
    When I make a GET request to the created file
      """
      Range: bytes=6-
      """
    Then I should see response status "206 Partial Content"
    And I should see response headers
      """
      Content-Range: bytes 6-10/11
      Content-Length: 5
      """
    And I should see "world"

  Scenario: Unfinished upload
    Given I've created a file
      """
      Upload-Length: 11
      """
    When I make a GET request to the created file
      """
      """
    Then I should see response status "403 Forbidden"
    And I should see "Cannot download unfinished upload"

  Scenario: Unknown upload
    When I make a GET request to /files/unknown
      """
      """
    Then I should see response status "404 Not Found"
    And I should see "Upload Not Found"
