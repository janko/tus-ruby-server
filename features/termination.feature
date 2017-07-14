Feature: Termination

  Scenario: Finished upload
    Given I've created a file
      """
      Upload-Length: 0
      """
    When I make a DELETE request to the created file
      """
      Tus-Resumable: 1.0.0
      """
    Then I should see response status "204 No Content"

    When I make a HEAD request to the created file
      """
      Tus-Resumable: 1.0.0
      """
    Then I should see response status "404 Not Found"

  Scenario: Unfinished upload
    Given I've created a file
      """
      Upload-Length: 10
      """
    When I make a DELETE request to the created file
      """
      Tus-Resumable: 1.0.0
      """
    Then I should see response status "204 No Content"

    When I make a HEAD request to the created file
      """
      Tus-Resumable: 1.0.0
      """
    Then I should see response status "404 Not Found"

  Scenario: Unknown upload
    When I make a DELETE request to /files/unknown
      """
      Tus-Resumable: 1.0.0
      """
    Then I should see response status "404 Not Found"
    And I should see "Upload Not Found"
