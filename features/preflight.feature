Feature: Preflight

  Scenario: Top Level
    When I make an OPTIONS request to /files
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
    And I should not see "Content-Type" response header
    And I should not see "Content-Length" response header

  Scenario: For Upload
    When I make an OPTIONS request to /files/uid
      """
      """
    Then I should see response status "204 No Content"
    And I should see response headers
      """
      Tus-Version: 1.0.0
      Tus-Extension: creation,creation-defer-length,termination,expiration,concatenation,checksum
      Tus-Checksum-Algorithm: sha1,sha256,sha384,sha512,md5,crc32
      """
    And I should not see "Content-Type" response header
    And I should not see "Content-Length" response header

  Scenario: Max Size
    When I make an OPTIONS request to /files
      """
      """
    Then I should not see "Tus-Max-Size" response header

    When I make an OPTIONS request to /files/uid
      """
      """
    Then I should not see "Tus-Max-Size" response header

    Given I've set max size to 10

    When I make an OPTIONS request to /files
      """
      """
    Then I should see response headers
      """
      Tus-Max-Size: 10
      """

    When I make an OPTIONS request to /files/uid
      """
      """
    Then I should see response headers
      """
      Tus-Max-Size: 10
      """
