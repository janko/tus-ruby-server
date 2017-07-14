Feature: Head

  Scenario: Existing file
    Given I've created a file
      """
      Upload-Length: 10
      """
    When I make a HEAD request to the created file
      """
      Tus-Resumable: 1.0.0
      """
    Then I should see response status "204 No Content"
    And I should see response headers
      """
      Upload-Length: 10
      Upload-Offset: 0
      """
    And I should see response headers
      """
      Cache-Control: no-store
      """

  Scenario: Nonexisting file
    When I make a HEAD request to /files/unknown
      """
      Tus-Resumable: 1.0.0
      """
    Then I should see response status "404 Not Found"

  Scenario: Missing Tus-Resumable
    Given I've created a file
      """
      Upload-Length: 10
      """
    When I make a HEAD request to the created file
      """
      """
    Then I should see response status "412 Precondition Failed"
