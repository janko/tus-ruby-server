Feature: Expiration

  Scenario: Expiration on creation
    When I make a POST request to "/files"
      """
      Tus-Resumable: 1.0.0
      Upload-Length: 10
      """
    Then "Upload-Expires" response header should match "^\w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} GMT$"

  Scenario: Refreshing expiration
    Given I've created a file
      """
      Upload-Length: 10
      """
    And I've set expiration time to 10 seconds
    When I append "hello" to the created file
    Then the expiration date should be refreshed
