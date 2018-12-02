Feature: Hooks

  Scenario: Before Create Hook
    Given I've registered a before_create hook
    When I create a file
      """
      Upload-Length: 11
      """
    Then the before_create hook should have been called

  Scenario: After Create Hook
    Given I've registered an after_create hook
    When I create a file
      """
      Upload-Length: 11
      """
    Then the after_create hook should have been called

  Scenario: After Finish Hook
    Given I've registered an after_finish hook

    When I create a file
      """
      Upload-Length: 11
      """
    Then the after_finish hook should not have been called

    When I append "hello" to the created file
    Then the after_finish hook should not have been called

    When I append " world" to the created file
    Then the after_finish hook should have been called

  Scenario: After Terminate Hook
    Given I've registered an after_terminate hook
    And a file
      """
      Upload-Length: 11

      hello world
      """
    When I delete the created file
    Then the after_terminate hook should have been called
