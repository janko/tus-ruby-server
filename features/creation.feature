Feature: Creation

  Scenario: Valid Upload-Length
    When I make a POST request to "/files"
      """
      Tus-Resumable: 1.0.0
      Upload-Length: 100
      """
    Then I should see response status "201 Created"
    And "Location" response header should match "^http://localhost/files/\w+$"
    And I should not see "Content-Type" response header

  Scenario: Invalid Upload-Length
    When I make a POST request to "/files"
      """
      Tus-Resumable: 1.0.0
      Upload-Length: foo
      """
    Then I should see response status "400 Bad Request"

    When I make a POST request to "/files"
      """
      Tus-Resumable: 1.0.0
      Upload-Length: -1
      """
    Then I should see response status "400 Bad Request"

  Scenario: Too large Upload-Length
    Given I've set max size to 10
    When I make a POST request to "/files"
      """
      Tus-Resumable: 1.0.0
      Upload-Length: 100
      """
    Then I should see response status "413 Request entity too large"

  Scenario: Missing Tus-Resumable
    When I make a POST request to "/files"
      """
      Upload-Length: 100
      """
    Then I should see response status "412 Precondition Failed"
