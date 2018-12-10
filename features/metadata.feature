Feature: Metadata

  Scenario: Persistence
    Given I've created a file
      """
      Upload-Length: 0
      Upload-Metadata: type dmlkZW8=,duration MTIw
      """
    When I make a HEAD request to the created file
      """
      Tus-Resumable: 1.0.0
      """
    Then I should see response headers
      """
      Upload-Metadata: type dmlkZW8=,duration MTIw
      """

  Scenario: Filename
    Given I've created a file
      """
      Upload-Length: 0
      Upload-Metadata: filename bmF0dXJlLmpwZw==
      """
    When I make a GET request to the created file
      """
      """
    Then I should see response headers
      """
      Content-Disposition: inline; filename="nature.jpg"
      """

  Scenario: Content Type
    Given I've created a file
      """
      Upload-Length: 0
      Upload-Metadata: content_type aW1hZ2UvanBlZw==
      """
    When I make a GET request to the created file
      """
      """
    Then I should see response headers
      """
      Content-Type: image/jpeg
      """

  Scenario: Blank metadata
    Given I've created a file
      """
      Upload-Length: 0
      Upload-Metadata: name
      """
    When I make a HEAD request to the created file
      """
      Tus-Resumable: 1.0.0
      """
    Then I should see response headers
      """
      Upload-Metadata: name
      """

  Scenario: Invalid format
    When I make a POST request to "/files"
      """
      Tus-Resumable: 1.0.0
      Upload-Length: 0
      Upload-Metadata: ❨╯°□°❩╯︵┻━┻  foo
      """
    Then I should see response status "400 Bad Request"

    When I make a POST request to "/files"
      """
      Tus-Resumable: 1.0.0
      Upload-Length: 0
      Upload-Metadata: foo *******
      """
    Then I should see response status "400 Bad Request"

    When I make a POST request to "/files"
      """
      Tus-Resumable: 1.0.0
      Upload-Length: 0
      Upload-Metadata: foo Zm9v bar YmFy
      """
    Then I should see response status "400 Bad Request"

  Scenario: No metadata
    Given I've created a file
      """
      Tus-Resumable: 1.0.0
      Upload-Length: 0
      """
    When I make a HEAD request to the created file
      """
      Tus-Resumable: 1.0.0
      """
    Then I should not see "Upload-Metadata" response header
