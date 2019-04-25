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
      Accept-Ranges: bytes
      Content-Length: 11
      """
    And I should see "hello world"

  Scenario: Content-Disposition (default)
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

  Scenario: Content-Disposition (from name)
    Given a file
      """
      Upload-Length: 11
      Upload-Metadata: name bmF0dXJlLmpwZw==

      hello world
      """
    When I make a GET request to the created file
      """
      """
    And I should see response headers
      """
      Content-Disposition: inline; filename="nature.jpg"; filename*=UTF-8''nature.jpg
      """

  Scenario: Content-Type (default)
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

  Scenario: Content-Type (from type)
    Given a file
      """
      Upload-Length: 11
      Upload-Metadata: type aW1hZ2UvanBlZw==

      hello world
      """
    When I make a GET request to the created file
      """
      """
    And I should see response headers
      """
      Content-Type: image/jpeg
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

  Scenario: ETag
    Given a file
      """
      Upload-Length: 11

      hello world
      """
    When I make a GET request to the created file
      """
      """
    Then "ETag" response header should match "W/\"\w+\""

  Scenario: Download URL (default)
    Given a file
      """
      Upload-Length: 11
      Upload-Metadata: name bmF0dXJlLmpwZw==,type aW1hZ2UvanBlZw==

      hello world
      """
    And download URL is enabled
    When I make a GET request to the created file
      """
      """
    Then I should see response status "302 Found"
    And I should see response headers
      """
      Location: https://example.org/file?content_type=image%2Fjpeg&content_disposition=inline%3B+filename%3D%22nature.jpg%22
      """
    And I should not see "Content-Type" response header
    And I should not see "Content-Disposition" response header

  Scenario: Download URL (defined)
    Given a file
      """
      Upload-Length: 11
      Upload-Metadata: name bmF0dXJlLmpwZw==,type aW1hZ2UvanBlZw==

      hello world
      """
    And download URL is defined
    When I make a GET request to the created file
      """
      """
    Then I should see response status "302 Found"
    And I should see response headers
      """
      Location: https://example.org/file?content_type=image%2Fjpeg&content_disposition=inline%3B+filename%3D%22nature.jpg%22
      """
    And I should not see "Content-Type" response header
    And I should not see "Content-Disposition" response header

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
    When I make a GET request to "/files/unknown"
      """
      """
    Then I should see response status "404 Not Found"
    And I should see "Upload Not Found"
