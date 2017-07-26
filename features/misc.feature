Feature: Misc

  Scenario: Method Override
    When I make a GET request to /files/unknown
      """
      X-HTTP-Method-Override: OPTIONS
      """
    Then I should see response headers
      """
      Tus-Version: 1.0.0
      """

  Scenario: Trailing Slash
    When I make an OPTIONS request to /files/
      """
      """
    Then I should see response status "204 No Content"
    And I should see response headers
      """
      Tus-Resumable: 1.0.0
      Tus-Version: 1.0.0
      Tus-Extension: creation,creation-defer-length,termination,expiration,concatenation,checksum
      Tus-Checksum-Algorithm: sha1,sha256,sha384,sha512,md5,crc32
      """

  Scenario: Not Allowed
    When I make a PUT request to /files
      """
      Tus-Resumable: 1.0.0
      """
    Then I should see response status "405 Not Allowed"

  Scenario: Missing Tus-Resumable
    When I make a POST request to /files
      """
      Upload-Length: 100
      """
    And I should see "Unsupported version"
    Then I should see response status "412 Precondition Failed"
    And I should see response headers
      """
      Tus-Version: 1.0.0
      """

  Scenario: Invalid Tus-Resumable
    When I make a POST request to /files
      """
      Tus-Resumable: 2.0.0
      Upload-Length: 100
      """
    And I should see "Unsupported version"
    Then I should see response status "412 Precondition Failed"
    And I should see response headers
      """
      Tus-Version: 1.0.0
      """
