import ThreeFingerSwitcherCore

// Thin executable: all app logic lives in the ThreeFingerSwitcherCore library so that a
// test target can `@testable import ThreeFingerSwitcherCore`. (A test target cannot
// @testable-import an executable module that contains top-level code.)
runThreeFingerSwitcher()
